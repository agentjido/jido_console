defmodule Jido.Console.Session.Legacy do
  @moduledoc false

  alias Jido.Console.Session.BindingManifest
  alias Jidoka.Session.Data

  @doc false
  @spec unused?(Data.t()) :: boolean()
  def unused?(%Data{} = session) do
    unrelated_metadata = Map.delete(session.metadata, BindingManifest.metadata_key())

    session_unused?(session) and unrelated_metadata == %{} and conversation_unused?(session.conversation)
  end

  defp session_unused?(session) do
    session.status == :new and session.requests == [] and session.snapshots == [] and
      is_nil(session.result) and is_nil(session.error) and is_nil(session.lease) and
      is_nil(session.environment) and is_nil(session.lineage)
  end

  defp conversation_unused?(conversation) do
    agent_unused?(conversation.agent_state) and conversation.continuation_revision == 0 and
      conversation.turn_count == 0 and conversation.context_state == %{} and
      is_nil(conversation.last_completed_request_id)
  end

  defp agent_unused?(agent_state) do
    agent_state.messages == [] and agent_state.metadata == %{} and agent_state.operation_results == []
  end
end
