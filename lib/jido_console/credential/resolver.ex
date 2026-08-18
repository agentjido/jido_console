defmodule Jido.Console.Credential.Resolver do
  @moduledoc "Resolves one exact credential reference only inside a final execution boundary."

  @dotenv_max_bytes 64 * 1_024
  @final_boundaries [:provider, :tool]
  @shell_fragments ["${", "$(", "`", ";", "&&", "||", "\n", "\r"]

  @type credential_reference :: map()

  @doc "Resolves one reference, calls the final boundary, and prevents the value from escaping."
  @spec materialize(credential_reference(), (binary() -> term()), keyword()) ::
          {:ok, term()} | {:error, term()}
  def materialize(reference, callback, opts \\ [])

  def materialize(reference, callback, opts) when is_map(reference) and is_function(callback, 1) do
    with :ok <- final_boundary(opts),
         {:ok, value} <- resolve(reference, opts) do
      call_boundary(callback, value)
    end
  end

  def materialize(_reference, _callback, _opts), do: {:error, :invalid_credential_materialization}

  defp final_boundary(opts) do
    case Keyword.get(opts, :boundary) do
      boundary when boundary in @final_boundaries -> :ok
      _other -> {:error, :credential_final_boundary_required}
    end
  end

  defp resolve(%{"kind" => "environment", "lookup" => %{"name" => name}} = reference, opts) do
    result =
      case Keyword.get(opts, :host_env) do
        host_env when is_map(host_env) -> Map.fetch(host_env, name)
        nil -> Keyword.get(opts, :env_fetch, &System.fetch_env/1).(name)
        _invalid -> :error
      end

    normalize_value(result, reference)
  rescue
    _exception -> unavailable(reference)
  catch
    _kind, _reason -> unavailable(reference)
  end

  defp resolve(
         %{"kind" => "private_dotenv", "lookup" => %{"file_identity" => identity, "variable" => variable}} =
           reference,
         opts
       ) do
    with {:ok, path} <- dotenv_path(identity, opts),
         {:ok, contents} <- read_private_dotenv(path, opts),
         result <- dotenv_value(contents, variable) do
      normalize_value(result, reference)
    else
      {:error, :denied} -> denied(reference)
      {:error, :missing} -> missing(reference)
      {:error, _reason} -> unavailable(reference)
    end
  end

  defp resolve(%{"kind" => "keychain_item", "lookup" => lookup} = reference, opts) do
    with :ok <- keychain_platform(opts),
         {:ok, adapter} <- keychain_adapter(opts) do
      adapter
      |> read_keychain(lookup, opts)
      |> normalize_value(reference)
    else
      {:error, _reason} -> unavailable(reference)
    end
  rescue
    _exception -> unavailable(reference)
  catch
    _kind, _reason -> unavailable(reference)
  end

  defp resolve(reference, _opts), do: unavailable(reference)

  defp dotenv_path(identity, opts) do
    case Keyword.get(opts, :dotenv_paths, %{}) do
      paths when is_map(paths) ->
        case Map.fetch(paths, identity) do
          {:ok, path} when is_binary(path) -> validate_dotenv_path(path)
          :error -> {:error, :missing}
          _invalid -> {:error, :denied}
        end

      _invalid ->
        {:error, :denied}
    end
  end

  defp validate_dotenv_path(path) do
    expanded = Path.expand(path)

    if Path.type(path) == :absolute and expanded == path,
      do: {:ok, path},
      else: {:error, :denied}
  end

  defp read_private_dotenv(path, opts) do
    expected_uid = Keyword.get_lazy(opts, :owner_uid, &default_owner_uid/0)

    case File.lstat(path) do
      {:ok, %{type: :regular, mode: mode, size: size, uid: uid}}
      when Bitwise.band(mode, 0o077) == 0 and size <= @dotenv_max_bytes and uid == expected_uid ->
        File.read(path)

      {:ok, %{type: :regular}} ->
        {:error, :denied}

      {:ok, _stat} ->
        {:error, :denied}

      {:error, :enoent} ->
        {:error, :missing}

      {:error, _reason} ->
        {:error, :denied}
    end
  end

  defp default_owner_uid do
    case File.stat(System.user_home!()) do
      {:ok, %{uid: uid}} -> uid
      {:error, _reason} -> -1
    end
  end

  defp dotenv_value(contents, variable) do
    contents
    |> String.split("\n")
    |> Enum.reduce_while(:error, fn line, found -> parse_dotenv_line(line, variable, found) end)
  end

  defp parse_dotenv_line(line, _variable, found) when line in ["", "\r"], do: {:cont, found}

  defp parse_dotenv_line("#" <> _comment, _variable, found), do: {:cont, found}

  defp parse_dotenv_line(line, variable, found) do
    line = String.trim_trailing(line, "\r")

    with [name, value] <- String.split(line, "=", parts: 2),
         true <- Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name),
         false <- unsafe_dotenv_value?(value),
         {:ok, value} <- normalize_dotenv_value(value) do
      cond do
        name != variable -> {:cont, found}
        match?({:ok, _value}, found) -> {:halt, {:error, :denied}}
        true -> {:cont, {:ok, value}}
      end
    else
      _invalid -> {:halt, {:error, :denied}}
    end
  end

  defp unsafe_dotenv_value?(value), do: Enum.any?(@shell_fragments, &String.contains?(value, &1))

  defp normalize_dotenv_value(<<quote, rest::binary>>) when quote in [?\", ?'] do
    if byte_size(rest) > 0 and String.ends_with?(rest, <<quote>>) do
      {:ok, binary_part(rest, 0, byte_size(rest) - 1)}
    else
      {:error, :denied}
    end
  end

  defp normalize_dotenv_value(value), do: {:ok, value}

  defp keychain_platform(opts) do
    platform = Keyword.get_lazy(opts, :platform, &current_platform/0)
    allowed = Keyword.get(opts, :keychain_platforms, ["darwin"])
    if platform in allowed, do: :ok, else: {:error, :unavailable}
  end

  defp current_platform do
    case :os.type() do
      {:unix, :darwin} -> "darwin"
      {family, name} -> "#{family}:#{name}"
    end
  end

  defp keychain_adapter(opts) do
    case Keyword.get(opts, :keychain_adapter) do
      adapter when is_function(adapter, 2) -> {:ok, adapter}
      adapter when is_atom(adapter) -> {:ok, adapter}
      _other -> {:error, :unavailable}
    end
  end

  defp read_keychain(adapter, lookup, opts) when is_function(adapter, 2), do: adapter.(lookup, opts)

  defp read_keychain(adapter, lookup, opts) when is_atom(adapter) do
    if function_exported?(adapter, :read, 2), do: adapter.read(lookup, opts), else: {:error, :unavailable}
  end

  defp normalize_value({:ok, value}, _reference) when is_binary(value) and value != "", do: {:ok, value}
  defp normalize_value({:ok, _invalid}, reference), do: unavailable(reference)
  defp normalize_value(:error, reference), do: missing(reference)
  defp normalize_value(:missing, reference), do: missing(reference)
  defp normalize_value({:error, :enoent}, reference), do: missing(reference)
  defp normalize_value({:error, :missing}, reference), do: missing(reference)
  defp normalize_value({:error, reason}, reference) when reason in [:eacces, :eperm, :denied], do: denied(reference)
  defp normalize_value({:error, _reason}, reference), do: unavailable(reference)
  defp normalize_value(_other, reference), do: unavailable(reference)

  defp call_boundary(callback, value) do
    result = callback.(value)

    if contains_value?(result, value),
      do: {:error, {:sensitive_result_blocked, %{"redacted" => true}}},
      else: {:ok, result}
  rescue
    exception -> {:error, {:credential_boundary_failed, exception.__struct__}}
  catch
    kind, _reason -> {:error, {:credential_boundary_failed, kind}}
  end

  defp contains_value?(value, secret) when is_binary(value), do: String.contains?(value, secret)
  defp contains_value?(value, secret) when is_list(value), do: Enum.any?(value, &contains_value?(&1, secret))

  defp contains_value?(value, secret) when is_map(value) do
    Enum.any?(value, fn {key, item} -> contains_value?(key, secret) or contains_value?(item, secret) end)
  end

  defp contains_value?(_value, _secret), do: false

  defp missing(reference), do: {:error, {:credential_source_missing, redacted(reference)}}
  defp denied(reference), do: {:error, {:credential_source_denied, redacted(reference)}}
  defp unavailable(reference), do: {:error, {:credential_source_unavailable, redacted(reference)}}

  defp redacted(reference) do
    Map.take(reference, ["reference_id", "kind", "source_identity"])
  end
end
