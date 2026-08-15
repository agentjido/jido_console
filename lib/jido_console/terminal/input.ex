defmodule Jido.Console.Terminal.Input do
  @moduledoc "Pure incremental decoder for the small Jido terminal input protocol."

  @paste_start "\e[200~"
  @paste_end "\e[201~"
  @sequences [
    {"\e[5~", {:key, :page_up}},
    {"\e[6~", {:key, :page_down}},
    {"\e[A", {:key, :up}},
    {"\e[B", {:key, :down}},
    {"\e[D", {:key, :left}},
    {"\e[C", {:key, :right}},
    {"\eOA", {:key, :up}},
    {"\eOB", {:key, :down}},
    {"\eOD", {:key, :left}},
    {"\eOC", {:key, :right}}
  ]

  defstruct buffer: "", paste: nil

  @type event :: Jido.Console.Terminal.Adapter.event()
  @type t :: %__MODULE__{buffer: binary(), paste: binary() | nil}

  @doc "Adds a byte chunk and returns all complete events."
  @spec feed(t(), binary()) :: {t(), [event()]}
  def feed(%__MODULE__{} = state, bytes) when is_binary(bytes) do
    state
    |> Map.update!(:buffer, &(&1 <> bytes))
    |> parse([])
  end

  @doc "Flushes an ambiguous Escape byte after the adapter timeout."
  @spec flush_escape(t()) :: {t(), [event()]}
  def flush_escape(%__MODULE__{paste: nil, buffer: <<27, rest::binary>>} = state) do
    %{state | buffer: rest}
    |> parse([{:key, :escape}])
  end

  def flush_escape(%__MODULE__{} = state), do: {state, []}

  @doc "Returns true when the decoder waits for an Escape sequence."
  @spec escape_pending?(t()) :: boolean()
  def escape_pending?(%__MODULE__{paste: nil, buffer: <<27, _rest::binary>>}), do: true
  def escape_pending?(%__MODULE__{}), do: false

  defp parse(%__MODULE__{paste: paste} = state, events) when is_binary(paste) do
    combined = paste <> state.buffer

    case :binary.match(combined, @paste_end) do
      {index, length} ->
        <<content::binary-size(^index), _marker::binary-size(^length), rest::binary>> = combined
        parse(%{state | buffer: rest, paste: nil}, [{:paste, content} | events])

      :nomatch ->
        {%{state | buffer: "", paste: combined}, Enum.reverse(events)}
    end
  end

  defp parse(%__MODULE__{buffer: ""} = state, events), do: {state, Enum.reverse(events)}

  defp parse(%__MODULE__{buffer: buffer} = state, events) do
    cond do
      String.starts_with?(buffer, @paste_start) ->
        <<_marker::binary-size(byte_size(@paste_start)), rest::binary>> = buffer
        parse(%{state | buffer: rest, paste: ""}, events)

      incomplete_prefix?(buffer, @paste_start) ->
        {state, Enum.reverse(events)}

      sequence = matching_sequence(buffer) ->
        {bytes, event} = sequence
        bytes_size = byte_size(bytes)
        <<_sequence::binary-size(^bytes_size), rest::binary>> = buffer
        parse(%{state | buffer: rest}, [event | events])

      incomplete_sequence?(buffer) ->
        {state, Enum.reverse(events)}

      true ->
        parse_byte(state, events)
    end
  end

  defp parse_byte(%__MODULE__{buffer: <<3, rest::binary>>} = state, events),
    do: parse(%{state | buffer: rest}, [{:key, :ctrl_c} | events])

  defp parse_byte(%__MODULE__{buffer: <<13, rest::binary>>} = state, events),
    do: parse(%{state | buffer: rest}, [{:key, :enter} | events])

  defp parse_byte(%__MODULE__{buffer: <<10, rest::binary>>} = state, events),
    do: parse(%{state | buffer: rest}, [{:key, :newline} | events])

  defp parse_byte(%__MODULE__{buffer: <<127, rest::binary>>} = state, events),
    do: parse(%{state | buffer: rest}, [{:key, :backspace} | events])

  defp parse_byte(%__MODULE__{buffer: <<8, rest::binary>>} = state, events),
    do: parse(%{state | buffer: rest}, [{:key, :backspace} | events])

  defp parse_byte(%__MODULE__{buffer: <<27, rest::binary>>} = state, events) do
    parse(%{state | buffer: rest}, [{:key, :escape} | events])
  end

  defp parse_byte(%__MODULE__{buffer: buffer} = state, events) do
    case next_utf8(buffer) do
      {:ok, character, rest} ->
        parse(%{state | buffer: rest}, [{:text, character} | events])

      :incomplete ->
        {state, Enum.reverse(events)}

      {:invalid, rest} ->
        parse(%{state | buffer: rest}, [{:text, "�"} | events])
    end
  end

  defp matching_sequence(buffer) do
    Enum.find(@sequences, fn {sequence, _event} -> String.starts_with?(buffer, sequence) end)
  end

  defp incomplete_sequence?(buffer) do
    String.starts_with?(buffer, "\e") and
      Enum.any?(@sequences, fn {sequence, _event} -> incomplete_prefix?(buffer, sequence) end)
  end

  defp incomplete_prefix?(buffer, sequence) do
    byte_size(buffer) < byte_size(sequence) and String.starts_with?(sequence, buffer)
  end

  defp next_utf8(<<codepoint::utf8, rest::binary>>),
    do: {:ok, <<codepoint::utf8>>, rest}

  defp next_utf8(<<first, rest::binary>>) do
    expected =
      cond do
        first in 0xC2..0xDF -> 2
        first in 0xE0..0xEF -> 3
        first in 0xF0..0xF4 -> 4
        true -> 1
      end

    if expected > 1 and byte_size(rest) + 1 < expected do
      :incomplete
    else
      {:invalid, rest}
    end
  end
end
