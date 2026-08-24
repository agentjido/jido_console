defmodule Jido.Console.Extensions.Setup do
  @moduledoc "Owns resolved extensions and derives runtime and trust views."

  alias Jido.Console.Digest

  @schema Zoi.struct(
            __MODULE__,
            %{
              entries: Zoi.array(Zoi.tuple({Zoi.string(), Zoi.map(), Zoi.map()})),
              trust: Zoi.any(),
              recover_coding_errors: Zoi.boolean() |> Zoi.optional() |> Zoi.default(false),
              runtime_definition: Zoi.any() |> Zoi.optional() |> Zoi.default(nil),
              runtime_definition_fingerprint: Zoi.string() |> Zoi.nullable() |> Zoi.optional() |> Zoi.default(nil)
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  @derive {Inspect, except: [:entries]}
  defstruct Zoi.Struct.struct_fields(@schema)

  @type runtime_entry :: map()
  @type trust_record :: map()
  @type entry :: {String.t(), runtime_entry(), trust_record()}
  @type trust :: :not_requested | {:trusted, map() | nil} | {:disabled, trust()}

  @opaque t :: %__MODULE__{
            entries: [entry()],
            trust: trust(),
            recover_coding_errors: boolean(),
            runtime_definition: term(),
            runtime_definition_fingerprint: String.t() | nil
          }

  @doc "Returns an empty setup for a request set with no enabled extensions."
  @spec not_requested() :: t()
  def not_requested, do: %__MODULE__{entries: [], trust: :not_requested}

  @doc "Builds a setup from paired runtime entries and public trust records."
  @spec trusted([{runtime_entry(), trust_record()}], map() | nil) :: t()
  def trusted(entries, project \\ nil) when is_list(entries) and (is_map(project) or is_nil(project)) do
    %__MODULE__{entries: Enum.map(entries, &normalize_entry!/1), trust: {:trusted, project}}
  end

  @doc "Marks the coding pack as disabled while retaining other resolved extensions."
  @spec disabled(t()) :: t()
  def disabled(%__MODULE__{} = setup), do: %{setup | trust: {:disabled, setup.trust}}

  @doc "Adds one paired runtime and trust entry to the front of a setup."
  @spec prepend(t(), runtime_entry(), trust_record(), keyword()) :: t()
  def prepend(%__MODULE__{} = setup, runtime, trust_record, opts \\ [])
      when is_map(runtime) and is_map(trust_record) and is_list(opts) do
    entry = normalize_entry!({runtime, trust_record})

    %{
      setup
      | entries: [entry | Enum.reject(setup.entries, &(elem(&1, 0) == elem(entry, 0)))],
        trust: {:trusted, nil},
        recover_coding_errors: Keyword.get(opts, :recover_coding_errors, setup.recover_coding_errors)
    }
  end

  @doc "Returns the private runtime registry for host creation."
  @spec registry(t()) :: %{optional(String.t()) => runtime_entry()}
  def registry(%__MODULE__{entries: entries}) do
    Map.new(entries, fn {id, runtime, _trust_record} -> {id, runtime} end)
  end

  @doc "Returns the portable public trust projection."
  @spec projection(t()) :: map()
  def projection(%__MODULE__{entries: entries, trust: trust}) do
    records = Enum.map(entries, &elem(&1, 2))
    project_trust(trust, records)
  end

  @doc "Reports if coding tool failures become retryable tool results."
  @spec recover_coding_errors?(t()) :: boolean()
  def recover_coding_errors?(%__MODULE__{recover_coding_errors: recover?}), do: recover?

  @doc "Attaches one portable trusted runtime definition to a resolved setup."
  @spec with_runtime_definition(t(), term()) :: {:ok, t()} | {:error, term()}
  def with_runtime_definition(%__MODULE__{} = setup, definition) do
    with {:ok, fingerprint} <- runtime_definition_fingerprint(definition) do
      {:ok,
       %{
         setup
         | runtime_definition: definition,
           runtime_definition_fingerprint: fingerprint
       }}
    end
  end

  @doc "Returns a deterministic fingerprint without serializing runtime capabilities."
  @spec runtime_definition_fingerprint(t() | term()) :: {:ok, String.t()} | {:error, term()}
  def runtime_definition_fingerprint(%__MODULE__{runtime_definition_fingerprint: fingerprint})
      when is_binary(fingerprint),
      do: {:ok, fingerprint}

  def runtime_definition_fingerprint(%__MODULE__{} = setup) do
    setup
    |> setup_definition()
    |> runtime_definition_fingerprint()
  end

  def runtime_definition_fingerprint(definition) do
    with {:ok, portable} <- portable(definition, []) do
      {:ok, Digest.semantic(:runtime_definition, portable)}
    else
      {:error, reason} -> {:error, {:nonportable_runtime_definition, reason}}
    end
  end

  @doc "Returns the attached or derived portable runtime definition."
  @spec runtime_definition(t()) :: term()
  def runtime_definition(%__MODULE__{runtime_definition: definition}) when not is_nil(definition),
    do: definition

  def runtime_definition(%__MODULE__{} = setup), do: setup_definition(setup)

  defp normalize_entry!({%{registration: %{identity: %{id: runtime_id}}} = runtime, %{"id" => trust_id} = trust_record})
       when is_binary(runtime_id) and runtime_id == trust_id do
    {runtime_id, runtime, trust_record}
  end

  defp normalize_entry!(entry), do: raise(ArgumentError, "invalid resolved extension entry: #{inspect(entry)}")

  defp setup_definition(%__MODULE__{entries: entries}) do
    %{
      "contract" => "jido_console.extensions.runtime_definition.v1",
      "extensions" =>
        Enum.map(entries, fn {id, runtime, trust} ->
          %{
            "id" => id,
            "registration" => registration_projection(runtime),
            "definition" => runtime_definition_projection(runtime),
            "trust" => trust
          }
        end)
    }
  end

  defp registration_projection(%{registration: %Jidoka.Extension.Registration{} = registration}),
    do: Jidoka.Extension.Registration.to_map(registration)

  defp registration_projection(_runtime), do: nil

  defp runtime_definition_projection(runtime) do
    Map.get(runtime, :runtime_definition, Map.get(runtime, :definition))
  end

  defp portable(value, _path)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp portable(value, _path) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp portable(%_{} = value, path),
    do: {:error, {:struct, Enum.reverse(path), value.__struct__}}

  defp portable(value, path) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, normalized} ->
      with {:ok, key} <- portable_key(key),
           {:ok, item} <- portable(item, [key | path]) do
        {:cont, {:ok, Map.put(normalized, key, item)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp portable(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, normalized} ->
      case portable(item, [index | path]) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp portable(value, path) when is_function(value), do: {:error, {:function, Enum.reverse(path)}}
  defp portable(value, path) when is_pid(value), do: {:error, {:process, Enum.reverse(path)}}
  defp portable(value, path) when is_port(value), do: {:error, {:port, Enum.reverse(path)}}
  defp portable(value, path) when is_reference(value), do: {:error, {:reference, Enum.reverse(path)}}
  defp portable(value, path), do: {:error, {:value, Enum.reverse(path), value}}

  defp portable_key(key) when is_binary(key), do: {:ok, key}
  defp portable_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp portable_key(key), do: {:error, {:map_key, key}}

  defp project_trust(:not_requested, _records), do: %{"status" => "not_requested"}

  defp project_trust({:trusted, nil}, records),
    do: %{"status" => "trusted", "records" => records}

  defp project_trust({:trusted, project}, records),
    do: %{"status" => "trusted", "project" => project, "records" => records}

  defp project_trust({:disabled, nested}, records) do
    %{"status" => "disabled", "other_extensions" => project_trust(nested, records)}
  end
end
