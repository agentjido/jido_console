defmodule Jido.Console.Session.ThreadResources do
  @moduledoc "Private coding and extension resources for one thread."

  alias Jido.Console.Coding.Setup
  alias Jido.Console.Error
  alias Jido.Console.Extensions
  alias Jidoka.Session.Data

  @schema Zoi.struct(
            __MODULE__,
            %{
              thread_id: Zoi.string() |> Zoi.min(1),
              agent: Zoi.any(),
              base_spec: Zoi.any(),
              setup_module: Zoi.atom(),
              setup: Zoi.any() |> Zoi.optional() |> Zoi.default(nil),
              extension_host: Zoi.any() |> Zoi.optional() |> Zoi.default(nil),
              runtime_opts: Zoi.any() |> Zoi.optional() |> Zoi.default([]),
              options: Zoi.any()
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @type t :: %__MODULE__{}

  @doc "Creates an unprepared private resource handle."
  @spec new(String.t(), module() | Jidoka.Agent.Spec.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(thread_id, agent, opts \\ []) when is_binary(thread_id) and is_list(opts) do
    with {:ok, spec} <- Jidoka.Agent.Spec.from_input(agent) do
      {:ok,
       %__MODULE__{
         thread_id: thread_id,
         agent: agent,
         base_spec: spec,
         setup_module: Keyword.get(opts, :setup_module, Setup),
         setup: nil,
         extension_host: nil,
         runtime_opts: [],
         options: opts
       }}
    end
  end

  @doc "Returns the specification that is safe to store before resource setup."
  @spec base_spec(t()) :: Jidoka.Agent.Spec.t()
  def base_spec(%__MODULE__{base_spec: spec}), do: spec

  @doc "Configures the model while the private resource handle is unprepared."
  @spec configure_model(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def configure_model(%__MODULE__{setup: nil} = resources, identity) when is_binary(identity) do
    {:ok, %{resources | options: Keyword.put(resources.options, :model, identity)}}
  end

  def configure_model(%__MODULE__{}, _identity) do
    {:error,
     Error.validation_error("Model selection is locked after resources are prepared", %{
       source: :session_model
     })}
  end

  @doc "Prepares resources and binds them to the current durable session."
  @spec prepare(t(), Data.t()) :: {:ok, t(), Data.t()} | {:error, term()}
  def prepare(%__MODULE__{setup: setup} = resources, %Data{} = session) when not is_nil(setup),
    do: {:ok, resources, session}

  def prepare(%__MODULE__{} = resources, %Data{} = session) do
    opts = Keyword.put(resources.options, :thread_id, resources.thread_id)

    case resources.setup_module.prepare(resources.agent, opts) do
      {:ok, setup} ->
        result =
          with {:ok, session} <- put_spec(session, setup.spec),
               {:ok, extension} <-
                 Extensions.open(session, session.spec.extensions, setup.extension_setup,
                   operations: Keyword.get(opts, :operations)
                 ) do
            runtime_opts =
              setup.turn_opts
              |> Keyword.merge(caller_runtime_opts(opts))
              |> Keyword.merge(extension.runtime_opts)

            {:ok,
             %__MODULE__{
               resources
               | setup: setup,
                 extension_host: extension.host,
                 runtime_opts: runtime_opts
             }, extension.session}
          end

        if match?({:error, _reason}, result), do: resources.setup_module.close(setup)
        result

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc "Prepares one prompt and its portable context."
  @spec prepare_prompt(t(), String.t(), map()) :: {:ok, String.t(), map()} | {:error, term()}
  def prepare_prompt(%__MODULE__{setup: nil}, _prompt, _context), do: {:error, :resources_not_prepared}

  def prepare_prompt(%__MODULE__{setup_module: module, setup: setup}, prompt, context)
      when is_binary(prompt) and is_map(context) do
    with {:ok, prompt, coding_context} <- module.prepare_prompt(setup, prompt) do
      {:ok, prompt, Map.merge(coding_context, context)}
    end
  end

  @doc "Returns runtime options without exposing the private handle."
  @spec runtime_opts(t()) :: keyword()
  def runtime_opts(%__MODULE__{runtime_opts: opts}), do: opts

  @doc "Returns safe resource status for Session.View."
  @spec status(t()) :: map()
  def status(%__MODULE__{setup: nil}), do: %{"status" => "not_prepared"}

  def status(%__MODULE__{setup: setup}) do
    %{
      "status" => "ready",
      "coding" => if(setup.pack_id, do: "enabled", else: "disabled"),
      "profile_id" => setup.profile_id
    }
  end

  @doc "Closes all private resources for this thread."
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = resources) do
    _ = Extensions.close(resources.extension_host)
    if resources.setup, do: resources.setup_module.close(resources.setup)
    :ok
  end

  defp put_spec(%Data{} = session, spec) do
    Data.from_input(%{session | spec: spec, agent_id: spec.id})
  end

  defp caller_runtime_opts(opts) do
    case Keyword.get(opts, :operations) do
      operations when is_function(operations, 3) ->
        Keyword.put(Keyword.get(opts, :turn_opts, []), :operations, operations)

      _operations ->
        Keyword.get(opts, :turn_opts, [])
    end
  end
end
