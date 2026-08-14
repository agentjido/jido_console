defmodule RateLimiter do
  @moduledoc "A fixed-window event limiter used by the live coding scenario."

  @spec allow?([integer()], integer(), pos_integer(), pos_integer()) ::
          {boolean(), [integer()]}
  def allow?(timestamps, now, limit, window_ms) do
    cutoff = now - window_ms
    recent = Enum.filter(timestamps, &(&1 > cutoff))
    allowed? = length(recent) <= limit

    {allowed?, [now | recent]}
  end
end
