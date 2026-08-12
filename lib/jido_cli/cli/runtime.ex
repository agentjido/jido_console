defmodule Jido.Cli.Runtime do
  @moduledoc "Injectable agent runtime boundary for the TUI."

  @type cancel_result :: {:ok, Jidoka.Cancellation.t()} | {:error, term()}

  @callback start_session(agent :: module(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback start_turn(session :: term(), prompt :: String.t(), owner :: pid(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback await(request :: term(), keyword()) :: term()
  @callback cancel(request :: term(), keyword()) :: cancel_result()
  @callback close_session(session :: term()) :: :ok | {:error, term()}

  @optional_callbacks close_session: 1
end

defmodule Jido.Cli.Runtime.Jidoka do
  @moduledoc false

  @behaviour Jido.Cli.Runtime

  defmodule Session do
    @moduledoc false
    @enforce_keys [:data, :host, :runtime_opts]
    defstruct [:data, :host, :runtime_opts]

    @type t :: %__MODULE__{
            data: Jidoka.Session.Data.t(),
            host: Jidoka.Extension.Host.t(),
            runtime_opts: keyword()
          }
  end

  defmodule Request do
    @moduledoc false
    @enforce_keys [:request, :session]
    defstruct [:request, :session]

    @type t :: %__MODULE__{request: term(), session: Session.t()}
  end

  @impl Jido.Cli.Runtime
  def start_session(agent, opts) do
    setup = Keyword.get(opts, :extension_setup, %{registry: %{}})
    opts = Keyword.delete(opts, :extension_setup)

    with {:ok, session} <- Jidoka.session(agent, opts),
         {:ok, extension_runtime} <-
           Jido.Cli.Extensions.open(session, session.spec.extensions, setup, :interactive,
             operations: Keyword.get(opts, :operations)
           ) do
      if extension_runtime.host do
        {:ok,
         %Session{
           data: extension_runtime.session,
           host: extension_runtime.host,
           runtime_opts: extension_runtime.runtime_opts
         }}
      else
        {:ok, session}
      end
    end
  end

  @impl Jido.Cli.Runtime
  def start_turn(%Session{} = session, prompt, owner, opts) do
    opts = opts |> Keyword.merge(session.runtime_opts) |> Keyword.put(:stream, true) |> Keyword.put(:stream_to, owner)

    case Jidoka.chat_async(session.data, prompt, opts) do
      {:ok, request} -> {:ok, %Request{request: request, session: session}}
      {:error, reason} -> {:error, reason}
    end
  end

  def start_turn(session, prompt, owner, opts) do
    opts = opts |> Keyword.put(:stream, true) |> Keyword.put(:stream_to, owner)
    Jidoka.chat_async(session, prompt, opts)
  end

  @impl Jido.Cli.Runtime
  def await(%Request{} = request, opts) do
    case Jidoka.await(request.request, opts) do
      {:ok, next_session, content} ->
        {:ok, %{request.session | data: next_session}, content}

      result ->
        result
    end
  end

  def await(request, opts), do: Jidoka.await(request, opts)

  @impl Jido.Cli.Runtime
  def cancel(%Request{} = request, opts), do: Jidoka.cancel(request.request, opts)
  def cancel(request, opts), do: Jidoka.cancel(request, opts)

  @impl Jido.Cli.Runtime
  def close_session(%Session{} = session) do
    Jido.Cli.Extensions.close(session.host)
    :ok
  end

  def close_session(_session), do: :ok
end
