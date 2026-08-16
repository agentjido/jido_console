defmodule Jido.Console.Extensions.Setup do
  @moduledoc "Owns resolved extensions and derives runtime and trust views."

  @schema Zoi.struct(
            __MODULE__,
            %{
              entries: Zoi.array(Zoi.tuple({Zoi.string(), Zoi.map(), Zoi.map()})),
              trust: Zoi.any(),
              recover_coding_errors: Zoi.boolean() |> Zoi.optional() |> Zoi.default(false)
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
            recover_coding_errors: boolean()
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

  defp normalize_entry!({%{registration: %{identity: %{id: runtime_id}}} = runtime, %{"id" => trust_id} = trust_record})
       when is_binary(runtime_id) and runtime_id == trust_id do
    {runtime_id, runtime, trust_record}
  end

  defp normalize_entry!(entry), do: raise(ArgumentError, "invalid resolved extension entry: #{inspect(entry)}")

  defp project_trust(:not_requested, _records), do: %{"status" => "not_requested"}

  defp project_trust({:trusted, nil}, records),
    do: %{"status" => "trusted", "records" => records}

  defp project_trust({:trusted, project}, records),
    do: %{"status" => "trusted", "project" => project, "records" => records}

  defp project_trust({:disabled, nested}, records) do
    %{"status" => "disabled", "other_extensions" => project_trust(nested, records)}
  end
end
