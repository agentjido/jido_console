defmodule Jido.Console.Session.ThreadResources do
  @moduledoc "Private post-lock coding and extension resources for one thread."

  alias Jido.Console.Coding.Setup
  alias Jido.Console.Error
  alias Jido.Console.Extensions
  alias Jido.Console.Session.Binding
  alias Jidoka.Session.Data

  @schema Zoi.struct(
            __MODULE__,
            %{
              thread_id: Zoi.string() |> Zoi.min(1),
              agent: Zoi.any(),
              base_spec: Zoi.any(),
              bound_spec: Zoi.any(),
              binding: Zoi.any() |> Zoi.optional() |> Zoi.default(nil),
              setup_module: Zoi.atom(),
              setup: Zoi.any() |> Zoi.optional() |> Zoi.default(nil),
              extension_host: Zoi.any() |> Zoi.optional() |> Zoi.default(nil),
              memory_store_pid: Zoi.any() |> Zoi.optional() |> Zoi.default(nil),
              runtime_definition_fingerprint: Zoi.any() |> Zoi.optional() |> Zoi.default(nil),
              runtime_opts: Zoi.any() |> Zoi.optional() |> Zoi.default([]),
              options: Zoi.any()
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @type t :: %__MODULE__{}

  @doc "Creates an unprepared private resource handle."
  @spec new(String.t(), Binding.t() | module() | Jidoka.Agent.Spec.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def new(thread_id, agent_or_binding, opts \\ [])

  def new(thread_id, %Binding{} = binding, opts)
      when is_binary(thread_id) and is_list(opts) do
    {:ok,
     %__MODULE__{
       thread_id: thread_id,
       agent: binding.bound_spec,
       base_spec: binding.base_spec,
       bound_spec: binding.bound_spec,
       binding: binding,
       setup_module: Keyword.get(opts, :setup_module, Setup),
       setup: nil,
       extension_host: nil,
       memory_store_pid: nil,
       runtime_definition_fingerprint: binding.runtime_definition_fingerprint,
       runtime_opts: [],
       options: Keyword.put(opts, :model, binding.model_id)
     }}
  end

  def new(thread_id, agent, opts) when is_binary(thread_id) and is_list(opts) do
    with {:ok, spec} <- Jidoka.Agent.Spec.from_input(agent) do
      {:ok,
       %__MODULE__{
         thread_id: thread_id,
         agent: agent,
         base_spec: spec,
         bound_spec: spec,
         binding: nil,
         setup_module: Keyword.get(opts, :setup_module, Setup),
         setup: nil,
         extension_host: nil,
         memory_store_pid: nil,
         runtime_definition_fingerprint: nil,
         runtime_opts: [],
         options: opts
       }}
    end
  end

  @doc "Returns the semantic specification that is safe to store before setup."
  @spec base_spec(t()) :: Jidoka.Agent.Spec.t()
  def base_spec(%__MODULE__{bound_spec: spec}), do: spec

  @doc "Returns the immutable bound semantic specification."
  @spec bound_spec(t()) :: Jidoka.Agent.Spec.t()
  def bound_spec(%__MODULE__{bound_spec: spec}), do: spec

  @doc "Configures the model while a legacy private resource handle is unprepared."
  @spec configure_model(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def configure_model(%__MODULE__{setup: nil, binding: nil} = resources, identity)
      when is_binary(identity) do
    {:ok, %{resources | options: Keyword.put(resources.options, :model, identity)}}
  end

  def configure_model(%__MODULE__{setup: nil, binding: %Binding{}}, _identity) do
    {:error,
     Error.validation_error("Model selection must rebuild the semantic binding", %{
       source: :session_model
     })}
  end

  def configure_model(%__MODULE__{}, _identity) do
    {:error,
     Error.validation_error("Model selection is locked after resources are prepared", %{
       source: :session_model
     })}
  end

  @doc "Prepares resources and derives a fresh runtime spec from the bound spec."
  @spec prepare(t(), Data.t()) :: {:ok, t(), Data.t()} | {:error, term()}
  def prepare(%__MODULE__{setup: setup} = resources, %Data{} = session)
      when not is_nil(setup),
      do: {:ok, resources, session}

  def prepare(%__MODULE__{} = resources, %Data{} = session) do
    opts = Keyword.put(resources.options, :thread_id, resources.thread_id)

    case resources.setup_module.prepare(setup_input(resources), opts) do
      {:ok, setup} ->
        case open_runtime(resources, setup, session, opts) do
          {:ok, _resources, _session} = success ->
            success

          {:error, _reason} = error ->
            resources.setup_module.close(setup)
            error
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp open_runtime(%__MODULE__{} = resources, setup, session, opts) do
    with {:ok, session} <- put_spec(session, setup.spec),
         {:ok, extension} <-
           Extensions.open(session, session.spec.extensions, setup.extension_setup,
             operations: Keyword.get(opts, :operations),
             expected_runtime_definition_fingerprint: expected_runtime_definition_fingerprint(resources)
           ),
         :ok <- validate_runtime_definition(resources, extension) do
      case memory_store(setup.spec, opts) do
        {:ok, memory_opts, memory_store_pid} ->
          runtime_opts =
            setup.turn_opts
            |> Keyword.merge(caller_runtime_opts(opts))
            |> Keyword.merge(memory_opts)
            |> Keyword.merge(extension.runtime_opts)

          {:ok,
           %__MODULE__{
             resources
             | setup: setup,
               extension_host: extension.host,
               memory_store_pid: memory_store_pid,
               runtime_definition_fingerprint: extension.runtime_definition_fingerprint,
               runtime_opts: runtime_opts
           }, extension.session}

        {:error, _reason} = error ->
          _ = Extensions.close(extension.host)
          error
      end
    end
  end

  @doc "Prepares one prompt and applies host context after caller context."
  @spec prepare_prompt(t(), String.t(), map()) ::
          {:ok, String.t(), map()} | {:error, term()}
  def prepare_prompt(%__MODULE__{setup: nil}, _prompt, _context),
    do: {:error, :resources_not_prepared}

  def prepare_prompt(%__MODULE__{setup_module: module, setup: setup}, prompt, context)
      when is_binary(prompt) and is_map(context) do
    with :ok <- reject_reserved_context(context),
         {:ok, prompt, host_context} <- module.prepare_prompt(setup, prompt) do
      {:ok, prompt, Map.merge(context, host_context)}
    end
  end

  @doc "Returns runtime options without exposing private handles."
  @spec runtime_opts(t()) :: keyword()
  def runtime_opts(%__MODULE__{runtime_opts: opts}), do: opts

  @doc "Returns the trusted runtime-definition fingerprint."
  @spec runtime_definition_fingerprint(t()) :: String.t() | nil
  def runtime_definition_fingerprint(%__MODULE__{runtime_definition_fingerprint: fingerprint}),
    do: fingerprint

  @doc "Returns safe resource status for Session.View."
  @spec status(t()) :: map()
  def status(%__MODULE__{setup: nil}), do: %{"status" => "not_prepared"}

  def status(%__MODULE__{setup: setup}) do
    %{
      "status" => "ready",
      "coding" => if(setup.pack_id, do: "enabled", else: "disabled"),
      "execution_policy_id" => Map.get(setup, :execution_policy_id, Map.get(setup, :profile_id))
    }
  end

  @doc "Closes all private resources for this thread."
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = resources) do
    _ = Extensions.close(resources.extension_host)
    if resources.setup, do: resources.setup_module.close(resources.setup)
    close_memory_store(resources.memory_store_pid)
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

  defp setup_input(%__MODULE__{binding: %Binding{} = binding}), do: binding
  defp setup_input(%__MODULE__{agent: agent}), do: agent

  defp expected_runtime_definition_fingerprint(%__MODULE__{binding: %Binding{} = binding}),
    do: binding.runtime_definition_fingerprint

  defp expected_runtime_definition_fingerprint(%__MODULE__{}), do: nil

  defp validate_runtime_definition(
         %__MODULE__{binding: %Binding{runtime_definition_fingerprint: fingerprint}},
         %{runtime_definition_fingerprint: fingerprint}
       ),
       do: :ok

  defp validate_runtime_definition(%__MODULE__{binding: %Binding{}}, _extension),
    do: {:error, :runtime_definition_fingerprint_mismatch}

  defp validate_runtime_definition(%__MODULE__{}, _extension), do: :ok

  defp memory_store(%{memory: nil}, _opts), do: {:ok, [], nil}
  defp memory_store(%{memory: %{enabled: false}}, _opts), do: {:ok, [], nil}

  defp memory_store(%{memory: %{enabled: true}}, opts) do
    case Keyword.get(opts, :memory_store) do
      nil ->
        with {:ok, pid} <- Jidoka.Memory.Store.InMemory.start_link() do
          {:ok, [memory_store: {Jidoka.Memory.Store.InMemory, [pid: pid]}], pid}
        end

      store ->
        {:ok, [memory_store: store], nil}
    end
  end

  defp reject_reserved_context(context) do
    collision =
      Enum.find(Map.keys(context), fn key ->
        key in ["jido_console", :jido_console, "coding", :coding]
      end)

    if collision,
      do: {:error, {:reserved_context_namespace, to_string(collision)}},
      else: :ok
  end

  defp close_memory_store(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Agent.stop(pid)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp close_memory_store(_pid), do: :ok
end
