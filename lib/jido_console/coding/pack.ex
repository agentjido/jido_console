defmodule Jido.Console.Coding.Pack do
  @moduledoc "Host-owned coding-pack selection and semantic overlay."

  alias Jidoka.Agent.Spec
  alias Jidoka.Extension.Request

  @reserved_id Jidoka.CodingPack.id()
  @disabled_values [false, :disabled, "disabled", nil]
  @built_in_definition_modules [
    Jidoka.CodingPack.Read,
    Jidoka.CodingPack.Search,
    Jidoka.CodingPack.Write,
    Jidoka.CodingPack.Edit,
    Jidoka.CodingPack.Shell,
    Jidoka.CodingPack.GitStatus,
    Jidoka.CodingPack.GitDiff,
    Jidoka.CodingPack.Verify
  ]

  @enforce_keys [:id, :state, :request]
  defstruct [:id, :state, :request]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          state: :enabled | :disabled,
          request: Request.t() | nil
        }

  @doc "Returns the host-reserved first-party coding-pack ID."
  @spec reserved_id() :: String.t()
  def reserved_id, do: @reserved_id

  @doc "Resolves a coding-pack choice without reading agent document data."
  @spec resolve(keyword()) :: {:ok, t()} | {:error, term()}
  def resolve(opts \\ [])

  def resolve(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      value =
        Keyword.get(
          opts,
          :coding_pack,
          Application.get_env(:jido_console, :coding_pack, @reserved_id)
        )

      from_input(value)
    else
      {:error, :invalid_coding_pack_options}
    end
  end

  def resolve(_opts), do: {:error, :invalid_coding_pack_options}

  @doc "Normalizes one explicit coding-pack value."
  @spec from_input(term()) :: {:ok, t()} | {:error, term()}
  def from_input(value) when value in @disabled_values do
    {:ok, %__MODULE__{id: nil, state: :disabled, request: nil}}
  end

  def from_input(value) when is_binary(value) and value != "" do
    if module_name?(value) do
      {:error, :coding_module_name_forbidden}
    else
      case Request.new(id: value) do
        {:ok, request} ->
          {:ok, %__MODULE__{id: value, state: :enabled, request: request}}

        {:error, _reason} ->
          {:error, {:invalid_coding_pack, value}}
      end
    end
  end

  def from_input(value), do: {:error, {:invalid_coding_pack, value}}

  @doc "Applies only the selected host request after removing the reserved request."
  @spec apply(t(), Spec.t()) :: {:ok, Spec.t()} | {:error, term()}
  def apply(%__MODULE__{} = pack, %Spec{} = spec) do
    retained =
      Enum.reject(spec.extensions, fn request ->
        request.id == @reserved_id or (pack.id && request.id == pack.id)
      end)

    extensions = if pack.request, do: [pack.request | retained], else: retained
    Spec.new(spec |> Map.from_struct() |> Map.put(:extensions, extensions))
  end

  def apply(_pack, _spec), do: {:error, :invalid_coding_pack_overlay}

  @doc "Returns the allowlisted pack projection used in manifests and context."
  @spec projection(t()) :: map()
  def projection(%__MODULE__{state: state, id: id}) do
    %{"id" => id, "status" => Atom.to_string(state)}
  end

  @doc "Returns portable trusted runtime-definition data for the selected pack."
  @spec runtime_definition(t(), keyword()) :: map()
  def runtime_definition(pack, opts \\ [])

  def runtime_definition(%__MODULE__{state: :disabled} = pack, _opts) do
    %{
      "contract" => "jido_console.coding_pack.runtime_definition.v1",
      "pack" => projection(pack),
      "registration" => nil,
      "operations" => []
    }
  end

  def runtime_definition(%__MODULE__{id: @reserved_id} = pack, opts) do
    disabled = Keyword.get(opts, :coding_disable_tools, [])
    replacements = replacement_definitions(Keyword.get(opts, :coding_replace_tools, %{}))

    operations =
      Jidoka.CodingPack.tool_ids()
      |> Enum.reject(&(&1 in disabled))
      |> Enum.map(fn id -> Map.get(replacements, id, %{"name" => id, "source" => "built_in"}) end)

    %{
      "contract" => "jido_console.coding_pack.runtime_definition.v1",
      "pack" => projection(pack),
      "registration" =>
        Jidoka.CodingPack.registration()
        |> Jidoka.Extension.Registration.to_map(),
      "definition_modules" => Enum.map(@built_in_definition_modules, &module_definition/1),
      "operations" => operations
    }
  end

  def runtime_definition(%__MODULE__{} = pack, _opts) do
    %{
      "contract" => "jido_console.coding_pack.runtime_definition.v1",
      "pack" => projection(pack),
      "registration" => %{"id" => pack.id, "source" => "trusted_host_registry"},
      "operations" => []
    }
  end

  @doc false
  @spec enabled?(t()) :: boolean()
  def enabled?(%__MODULE__{state: :enabled}), do: true
  def enabled?(%__MODULE__{}), do: false

  @doc "Returns the host semantic instructions for the first-party pack."
  @spec instructions(t()) :: String.t()
  def instructions(%__MODULE__{id: @reserved_id, state: :enabled}) do
    """
    Local coding tools are available. Use the exact full operation names below.
    Return one top-level decision, then stop and wait for the tool observation.
    Do not simulate later tool calls and do not ask the user to supply tool output.

    Minimal valid calls:
    - coding.read: {"path":"relative/file"}
    - coding.search: {"mode":"text","path":".","pattern":"literal text"}
    - coding.search (list paths): {"mode":"path","path":".","pattern":"*"}
    - coding.edit: {"path":"relative/file","old_text":"exact text","new_text":"replacement"}
    - coding.write: {"path":"relative/file","content":"complete content"}
    - coding.git_status: {}
    - coding.git_diff: {}
    - coding.verify: {"helper_id":"mix-test"}

    There is no general shell operation. Never shorten an operation name, such
    as `read`, `edit`, or `verify`. A path value must be a plain relative path.
    Do not include quotation-mark characters inside the path value.
    Use coding.search with mode `path` to list files or directories.
    coding.git_status shows changed files only. A clean status does not mean
    that the directory is empty.
    For a repository overview, inspect the repository instead of answering from project instructions alone.
    Start with a root path search, then read the README and the main build manifest when they exist.
    For a normal text read, omit byte offsets and lengths unless you continue a truncated result.
    Line ranges are one-based. The first valid start_line or end_line value is 1.
    """
  end

  def instructions(%__MODULE__{}), do: ""

  defp replacement_definitions(entries) when is_map(entries) or is_list(entries) do
    entries
    |> Enum.reduce(%{}, fn
      {id, %{operation: %Jidoka.Agent.Spec.Operation{} = operation}}, definitions when is_binary(id) ->
        Map.put(definitions, id, Jidoka.project(operation))

      _entry, definitions ->
        definitions
    end)
  end

  defp replacement_definitions(_entries), do: %{}

  defp module_definition(module) do
    %{
      "module" => Atom.to_string(module),
      "md5" => module.module_info(:md5) |> Base.encode16(case: :lower)
    }
  end

  defp module_name?(value),
    do: String.starts_with?(value, ["Elixir.", ":"]) or String.contains?(value, "/")
end
