defmodule Jido.Console.Session.Legacy do
  @moduledoc false

  alias Jido.Console.Session.BindingManifest
  alias Jidoka.Session.Data

  @doc false
  @spec unused?(Data.t()) :: boolean()
  def unused?(%Data{} = session) do
    unrelated_metadata = Map.delete(session.metadata, BindingManifest.metadata_key())
    conversation = session.conversation

    session.status == :new and session.requests == [] and session.snapshots == [] and
      session.result == nil and session.error == nil and session.lease == nil and
      session.environment == nil and session.lineage == nil and unrelated_metadata == %{} and
      conversation.agent_state.messages == [] and conversation.agent_state.metadata == %{} and
      conversation.agent_state.operation_results == [] and
      conversation.continuation_revision == 0 and conversation.turn_count == 0 and
      conversation.context_state == %{} and is_nil(conversation.last_completed_request_id)
  end
end
