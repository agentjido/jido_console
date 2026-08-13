defmodule Jido.Cli.Runtime do
  @moduledoc "Injectable agent runtime boundary for the TUI."

  @type cancel_result :: {:ok, Jidoka.Cancellation.t()} | {:error, term()}

  @callback start_session(agent :: module() | Jidoka.Agent.Spec.t(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback start_turn(session :: term(), prompt :: String.t(), owner :: pid(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback await(request :: term(), keyword()) :: term()
  @callback cancel(request :: term(), keyword()) :: cancel_result()
  @callback approve(result :: term(), review :: term(), keyword()) :: term()
  @callback deny(result :: term(), review :: term(), keyword()) :: term()
  @callback close_session(session :: term()) :: :ok | {:error, term()}

  @optional_callbacks approve: 3, deny: 3, close_session: 1
end

defmodule Jido.Cli.Runtime.Jidoka do
  @moduledoc false

  @behaviour Jido.Cli.Runtime

  defmodule Session do
    @moduledoc false
    @enforce_keys [:data, :extension_host, :runtime_opts, :local_resources]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            data: Jidoka.Session.Data.t(),
            extension_host: Jidoka.Extension.Host.t() | nil,
            runtime_opts: keyword(),
            local_resources: Jido.Cli.Coding.Local.Resources.t() | nil
          }
  end

  defmodule Request do
    @moduledoc false
    @enforce_keys [
      :request_id,
      :request,
      :session,
      :runtime_opts,
      :extension_host,
      :local_resources
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            request_id: String.t(),
            request: term(),
            session: Session.t(),
            runtime_opts: keyword(),
            extension_host: Jidoka.Extension.Host.t() | nil,
            local_resources: Jido.Cli.Coding.Local.Resources.t() | nil
          }
  end

  defmodule Result do
    @moduledoc false
    @statuses [:ok, :error, :cancelled, :hibernated, :pending_review]
    @approvals [:approved, :denied]
    @enforce_keys [
      :request_id,
      :status,
      :session,
      :runtime_opts,
      :extension_host,
      :local_resources,
      :handle
    ]
    defstruct @enforce_keys ++
                [
                  :content,
                  :error,
                  :cancellation,
                  :snapshot,
                  :approval,
                  pending_reviews: [],
                  coding_reviews: [],
                  raw: nil
                ]

    @type status :: :ok | :error | :cancelled | :hibernated | :pending_review
    @type approval :: :approved | :denied | nil
    @type t :: %__MODULE__{
            request_id: String.t(),
            status: status(),
            session: Session.t(),
            runtime_opts: keyword(),
            extension_host: Jidoka.Extension.Host.t() | nil,
            local_resources: Jido.Cli.Coding.Local.Resources.t() | nil,
            handle: Request.t(),
            content: String.t() | nil,
            error: term() | nil,
            cancellation: Jidoka.Cancellation.t() | nil,
            snapshot: Jidoka.Snapshot.t() | nil,
            approval: approval(),
            pending_reviews: [Jidoka.Review.Request.t()],
            coding_reviews: [map()],
            raw: term()
          }

    @doc false
    @spec statuses() :: [status()]
    def statuses, do: @statuses

    @doc false
    @spec approvals() :: [approval()]
    def approvals, do: @approvals
  end

  @impl Jido.Cli.Runtime
  def start_session(agent, opts) do
    setup = Keyword.get(opts, :extension_setup, %{registry: %{}})
    local_resources = Keyword.get(opts, :local_resources)
    agent = Keyword.get(opts, :agent_spec_override, agent)
    opts = Keyword.drop(opts, [:extension_setup, :agent_spec_override, :local_resources])

    with {:ok, session} <- Jidoka.session(agent, opts),
         {:ok, extension_runtime} <-
           Jido.Cli.Extensions.open(session, session.spec.extensions, setup, :interactive,
             operations: Keyword.get(opts, :operations)
           ) do
      {:ok,
       %Session{
         data: extension_runtime.session,
         extension_host: extension_runtime.host,
         runtime_opts: extension_runtime.runtime_opts,
         local_resources: local_resources
       }}
    end
  end

  @impl Jido.Cli.Runtime
  def start_turn(%Session{} = session, prompt, owner, opts) do
    opts = runtime_opts(session, opts, owner)

    case Jidoka.chat_async(session.data, prompt, opts) do
      {:ok, request} ->
        runtime_opts = Keyword.put(opts, :request_id, request.request_id)

        {:ok,
         %Request{
           request_id: request.request_id,
           request: request,
           session: session,
           runtime_opts: runtime_opts,
           extension_host: session.extension_host,
           local_resources: session.local_resources
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def start_turn(%Jidoka.Session.Data{} = data, prompt, owner, opts) do
    session = session(data)
    start_turn(session, prompt, owner, opts)
  end

  def start_turn(_session, _prompt, _owner, _opts), do: {:error, :invalid_cli_runtime_session}

  @impl Jido.Cli.Runtime
  def await(%Request{} = request, opts) do
    request.request
    |> Jidoka.await(opts)
    |> normalize_result(request)
  end

  def await(_request, _opts), do: {:error, :invalid_cli_runtime_request}

  @impl Jido.Cli.Runtime
  def cancel(%Request{} = request, opts), do: Jidoka.cancel(request.request, opts)
  def cancel(request, opts), do: Jidoka.cancel(request, opts)

  @impl Jido.Cli.Runtime
  def approve(%Result{} = result, review, opts) do
    respond_to_review(result, review, opts, :approved)
  end

  @impl Jido.Cli.Runtime
  def deny(%Result{} = result, review, opts) do
    respond_to_review(result, review, opts, :denied)
  end

  @impl Jido.Cli.Runtime
  def close_session(%Session{} = session) do
    Jido.Cli.Extensions.close(session.extension_host)
    :ok
  end

  def close_session(_session), do: :ok

  defp runtime_opts(%Session{} = session, opts, owner) do
    opts
    |> Keyword.merge(session.runtime_opts)
    |> Keyword.put(:stream, true)
    |> Keyword.put(:stream_to, owner)
  end

  defp normalize_result({:ok, next_session, content} = raw, %Request{} = request) when is_binary(content) do
    session = put_session_data(request.session, next_session)

    result(request, session, :ok,
      content: content,
      coding_reviews: Jido.Cli.Coding.Review.from_session(next_session),
      raw: raw
    )
  end

  defp normalize_result({:ok, next_session, %Jidoka.Turn.Result{} = turn_result} = raw, request) do
    session = put_session_data(request.session, next_session)

    result(request, session, :ok,
      content: turn_result.content,
      coding_reviews: Jido.Cli.Coding.Review.from_session(next_session),
      raw: raw
    )
  end

  defp normalize_result({:hibernate, next_session, %Jidoka.Snapshot{} = snapshot} = raw, request) do
    session = put_session_data(request.session, next_session)
    {status, pending_reviews, error} = pending_review_state(snapshot)

    result(request, session, status,
      snapshot: snapshot,
      pending_reviews: pending_reviews,
      error: error,
      raw: raw
    )
  end

  defp normalize_result({:hibernate, %Jidoka.Snapshot{} = snapshot} = raw, request) do
    {status, pending_reviews, error} = pending_review_state(snapshot)

    result(request, request.session, status,
      snapshot: snapshot,
      pending_reviews: pending_reviews,
      error: error,
      raw: raw
    )
  end

  defp normalize_result({:cancelled, %Jidoka.Cancellation{} = cancellation} = raw, request) do
    result(request, request.session, :cancelled, cancellation: cancellation, raw: raw)
  end

  defp normalize_result({:error, reason} = raw, request) do
    result(request, request.session, :error, error: reason, raw: raw)
  end

  defp normalize_result(raw, request) do
    result(request, request.session, :error, error: {:invalid_runtime_result, raw}, raw: raw)
  end

  defp respond_to_review(%Result{} = result, review, opts, approval) do
    runtime_opts = result.runtime_opts |> Keyword.merge(opts) |> Keyword.delete(:request_id)

    raw =
      case approval do
        :approved -> Jidoka.approve(result.session.data, review, runtime_opts)
        :denied -> Jidoka.deny(result.session.data, review, runtime_opts)
      end

    result.handle
    |> put_request_session(result.session, result.runtime_opts)
    |> then(&normalize_result(raw, &1))
    |> Map.put(:approval, approval)
  end

  defp pending_review_state(snapshot) do
    case Jidoka.pending_reviews(snapshot) do
      {:ok, []} -> {:hibernated, [], nil}
      {:ok, pending_reviews} -> {:pending_review, pending_reviews, nil}
      {:error, reason} -> {:hibernated, [], {:pending_review_lookup_failed, reason}}
    end
  end

  defp result(request, session, status, attrs) do
    struct!(
      Result,
      Keyword.merge(
        [
          request_id: request.request_id,
          status: status,
          session: session,
          runtime_opts: request.runtime_opts,
          extension_host: request.extension_host,
          local_resources: request.local_resources,
          handle: request
        ],
        attrs
      )
    )
  end

  defp session(data) do
    %Session{
      data: data,
      extension_host: nil,
      runtime_opts: [],
      local_resources: nil
    }
  end

  defp put_session_data(%Session{} = session, %Jidoka.Session.Data{} = data),
    do: %Session{session | data: data}

  defp put_request_session(%Request{} = request, session, runtime_opts) do
    %Request{request | session: session, runtime_opts: runtime_opts}
  end
end
