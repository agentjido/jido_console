defmodule Jido.Console.Runtime do
  @moduledoc "Injectable agent runtime boundary for the TUI."

  defmodule Result do
    @moduledoc "A runtime-independent turn result with one closed outcome."

    @type approval :: :approved | :denied | nil

    defmodule Ok do
      @moduledoc false
      @enforce_keys [:content, :coding_reviews, :approval]
      defstruct @enforce_keys

      @type t :: %__MODULE__{
              content: String.t(),
              coding_reviews: [Jido.Console.Coding.Review.projection()],
              approval: Jido.Console.Runtime.Result.approval()
            }
    end

    defmodule PendingReview do
      @moduledoc false
      @enforce_keys [:reviews, :snapshot, :approval]
      defstruct @enforce_keys

      @type t :: %__MODULE__{
              reviews: [term()],
              snapshot: term(),
              approval: Jido.Console.Runtime.Result.approval()
            }
    end

    defmodule Hibernated do
      @moduledoc false
      @enforce_keys [:snapshot, :reason, :approval]
      defstruct @enforce_keys

      @type t :: %__MODULE__{
              snapshot: term(),
              reason: term() | nil,
              approval: Jido.Console.Runtime.Result.approval()
            }
    end

    defmodule Cancelled do
      @moduledoc false
      @enforce_keys [:cancellation, :approval]
      defstruct @enforce_keys

      @type t :: %__MODULE__{
              cancellation: term(),
              approval: Jido.Console.Runtime.Result.approval()
            }
    end

    defmodule Error do
      @moduledoc false
      @enforce_keys [:reason, :approval]
      defstruct @enforce_keys

      @type t :: %__MODULE__{
              reason: term(),
              approval: Jido.Console.Runtime.Result.approval()
            }
    end

    @enforce_keys [:request_id, :session, :handle, :outcome]
    defstruct @enforce_keys ++ [raw: nil]

    @type outcome :: Ok.t() | PendingReview.t() | Hibernated.t() | Cancelled.t() | Error.t()
    @type t :: %__MODULE__{
            request_id: String.t(),
            session: term(),
            handle: term(),
            outcome: outcome(),
            raw: term()
          }

    @spec ok(String.t(), term(), term(), String.t(), keyword()) :: t()
    def ok(request_id, session, handle, content, opts \\ []) when is_binary(content) do
      coding_reviews =
        opts
        |> Keyword.get(:coding_review_candidates, [])
        |> Jido.Console.Coding.Review.project_candidates()

      build(
        request_id,
        session,
        handle,
        %Ok{
          content: content,
          coding_reviews: coding_reviews,
          approval: Keyword.get(opts, :approval)
        },
        opts
      )
    end

    @spec pending_review(String.t(), term(), term(), [term()], keyword()) :: t()
    def pending_review(request_id, session, handle, reviews, opts \\ [])
        when is_list(reviews) and reviews != [] do
      build(
        request_id,
        session,
        handle,
        %PendingReview{
          reviews: reviews,
          snapshot: Keyword.get(opts, :snapshot),
          approval: Keyword.get(opts, :approval)
        },
        opts
      )
    end

    @spec hibernated(String.t(), term(), term(), keyword()) :: t()
    def hibernated(request_id, session, handle, opts \\ []) do
      build(
        request_id,
        session,
        handle,
        %Hibernated{
          snapshot: Keyword.get(opts, :snapshot),
          reason: Keyword.get(opts, :reason),
          approval: Keyword.get(opts, :approval)
        },
        opts
      )
    end

    @spec cancelled(String.t(), term(), term(), term(), keyword()) :: t()
    def cancelled(request_id, session, handle, cancellation, opts \\ []) do
      build(
        request_id,
        session,
        handle,
        %Cancelled{cancellation: cancellation, approval: Keyword.get(opts, :approval)},
        opts
      )
    end

    @spec error(String.t(), term(), term(), term(), keyword()) :: t()
    def error(request_id, session, handle, reason, opts \\ []) do
      build(
        request_id,
        session,
        handle,
        %Error{reason: reason, approval: Keyword.get(opts, :approval)},
        opts
      )
    end

    @spec status(t()) :: :ok | :pending_review | :hibernated | :cancelled | :error
    def status(%__MODULE__{outcome: %Ok{}}), do: :ok
    def status(%__MODULE__{outcome: %PendingReview{}}), do: :pending_review
    def status(%__MODULE__{outcome: %Hibernated{}}), do: :hibernated
    def status(%__MODULE__{outcome: %Cancelled{}}), do: :cancelled
    def status(%__MODULE__{outcome: %Error{}}), do: :error

    defp build(request_id, session, handle, outcome, opts) do
      %__MODULE__{
        request_id: request_id,
        session: session,
        handle: handle,
        outcome: outcome,
        raw: Keyword.get(opts, :raw)
      }
    end
  end

  @type cancel_result :: {:ok, Jidoka.Cancellation.t()} | {:error, term()}

  @callback start_session(agent :: module() | Jidoka.Agent.Spec.t(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback start_turn(session :: term(), prompt :: String.t(), owner :: pid(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback await(request :: term(), keyword()) :: Result.t() | {:error, term()}
  @callback cancel(request :: term(), keyword()) :: cancel_result()
  @callback approve(result :: Result.t(), review :: term(), keyword()) :: Result.t()
  @callback deny(result :: Result.t(), review :: term(), keyword()) :: Result.t()
  @callback close_session(session :: term()) :: :ok | {:error, term()}

  @optional_callbacks approve: 3, deny: 3, close_session: 1
end

defmodule Jido.Console.Runtime.Jidoka do
  @moduledoc false

  @behaviour Jido.Console.Runtime

  alias Jido.Console.Runtime.Result

  defmodule Session do
    @moduledoc false
    @enforce_keys [:data, :extension_host, :runtime_opts, :local_resources]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            data: Jidoka.Session.Data.t(),
            extension_host: Jidoka.Extension.Host.t() | nil,
            runtime_opts: keyword(),
            local_resources: Jido.Console.Coding.Local.Resources.t() | nil
          }
  end

  defmodule Request do
    @moduledoc false
    @enforce_keys [:request_id, :request, :session, :runtime_opts]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            request_id: String.t(),
            request: term(),
            session: Session.t(),
            runtime_opts: keyword()
          }
  end

  @impl Jido.Console.Runtime
  def start_session(agent, opts) do
    setup = Keyword.get(opts, :extension_setup, %{registry: %{}})
    local_resources = Keyword.get(opts, :local_resources)
    agent = Keyword.get(opts, :agent_spec_override, agent)
    opts = Keyword.drop(opts, [:extension_setup, :agent_spec_override, :local_resources])

    with {:ok, session} <- Jidoka.session(agent, opts),
         {:ok, extension_runtime} <-
           Jido.Console.Extensions.open(session, session.spec.extensions, setup, :interactive,
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

  @impl Jido.Console.Runtime
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
           runtime_opts: runtime_opts
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def start_turn(_session, _prompt, _owner, _opts), do: {:error, :invalid_cli_runtime_session}

  @impl Jido.Console.Runtime
  def await(%Request{} = request, opts) do
    request.request
    |> Jidoka.await(opts)
    |> normalize_result(request)
  end

  def await(_request, _opts), do: {:error, :invalid_cli_runtime_request}

  @impl Jido.Console.Runtime
  def cancel(%Request{} = request, opts), do: Jidoka.cancel(request.request, opts)
  def cancel(request, opts), do: Jidoka.cancel(request, opts)

  @impl Jido.Console.Runtime
  def approve(%Result{outcome: %Result.PendingReview{}} = result, review, opts) do
    respond_to_review(result, review, opts, :approved)
  end

  @impl Jido.Console.Runtime
  def deny(%Result{outcome: %Result.PendingReview{}} = result, review, opts) do
    respond_to_review(result, review, opts, :denied)
  end

  @impl Jido.Console.Runtime
  def close_session(%Session{} = session) do
    Jido.Console.Extensions.close(session.extension_host)
    :ok
  end

  def close_session(_session), do: :ok

  defp runtime_opts(%Session{} = session, opts, owner) do
    opts
    |> Keyword.merge(session.runtime_opts)
    |> Keyword.put(:stream, true)
    |> Keyword.put(:stream_to, owner)
  end

  defp normalize_result(raw, request, approval \\ nil)

  defp normalize_result({:ok, next_session, content} = raw, %Request{} = request, approval)
       when is_binary(content) do
    session = put_session_data(request.session, next_session)

    Result.ok(request.request_id, session, put_request_session(request, session), content,
      coding_review_candidates: Jido.Console.Coding.Review.candidates_from_session(next_session),
      approval: approval,
      raw: raw
    )
  end

  defp normalize_result(
         {:ok, next_session, %Jidoka.Turn.Result{} = turn_result} = raw,
         request,
         approval
       ) do
    session = put_session_data(request.session, next_session)

    Result.ok(request.request_id, session, put_request_session(request, session), turn_result.content,
      coding_review_candidates: Jido.Console.Coding.Review.candidates_from_session(next_session),
      approval: approval,
      raw: raw
    )
  end

  defp normalize_result(
         {:hibernate, next_session, %Jidoka.Snapshot{} = snapshot} = raw,
         request,
         approval
       ) do
    session = put_session_data(request.session, next_session)
    paused_result(request, session, snapshot, raw, approval)
  end

  defp normalize_result({:hibernate, %Jidoka.Snapshot{} = snapshot} = raw, request, approval) do
    paused_result(request, request.session, snapshot, raw, approval)
  end

  defp normalize_result(
         {:cancelled, %Jidoka.Cancellation{} = cancellation} = raw,
         request,
         approval
       ) do
    Result.cancelled(request.request_id, request.session, put_request_session(request, request.session), cancellation,
      approval: approval,
      raw: raw
    )
  end

  defp normalize_result({:error, reason} = raw, request, approval) do
    Result.error(request.request_id, request.session, put_request_session(request, request.session), reason,
      approval: approval,
      raw: raw
    )
  end

  defp normalize_result(raw, request, approval) do
    Result.error(
      request.request_id,
      request.session,
      put_request_session(request, request.session),
      {:invalid_runtime_result, raw},
      approval: approval,
      raw: raw
    )
  end

  defp respond_to_review(%Result{} = result, review, opts, approval) do
    runtime_opts = result.handle.runtime_opts |> Keyword.merge(opts) |> Keyword.delete(:request_id)

    raw =
      case approval do
        :approved -> Jidoka.approve(result.session.data, review, runtime_opts)
        :denied -> Jidoka.deny(result.session.data, review, runtime_opts)
      end

    result.handle
    |> put_request_session(result.session)
    |> then(&normalize_result(raw, &1, approval))
  end

  defp paused_result(request, session, snapshot, raw, approval) do
    handle = put_request_session(request, session)

    case Jidoka.pending_reviews(snapshot) do
      {:ok, []} ->
        Result.hibernated(request.request_id, session, handle,
          snapshot: snapshot,
          approval: approval,
          raw: raw
        )

      {:ok, pending_reviews} ->
        Result.pending_review(request.request_id, session, handle, pending_reviews,
          snapshot: snapshot,
          approval: approval,
          raw: raw
        )

      {:error, reason} ->
        Result.hibernated(request.request_id, session, handle,
          snapshot: snapshot,
          reason: {:pending_review_lookup_failed, reason},
          approval: approval,
          raw: raw
        )
    end
  end

  defp put_session_data(%Session{} = session, %Jidoka.Session.Data{} = data),
    do: %Session{session | data: data}

  defp put_request_session(%Request{} = request, session), do: %Request{request | session: session}
end
