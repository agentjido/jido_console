defmodule Jido.Cli.Automation.ReplayProjection do
  @moduledoc "Builds safe capability replay values for plans and results."

  @doc "Returns safe planning provenance."
  @spec projection(map()) :: map()
  def projection(%{mode: :live}) do
    %{
      mode: :live,
      status: :not_replayed,
      recorded_evidence: false,
      matched_calls: 0,
      total_calls: 0
    }
  end

  def projection(%{mode: :replay} = replay) do
    %{
      mode: :replay,
      status: :configured,
      fixture_schema: replay.fixture.version,
      fixture_digest: replay.fixture.digest,
      recorded_evidence: true,
      matched_calls: 0,
      total_calls: length(replay.fixture.entries)
    }
  end
end
