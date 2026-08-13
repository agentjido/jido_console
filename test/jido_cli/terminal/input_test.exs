defmodule Jido.Cli.Terminal.InputTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Terminal.Input

  test "decodes text, control keys, and arrow sequences" do
    {_state, events} = Input.feed(%Input{}, "a\r\x7f\x03\e[D\e[C")

    assert events == [
             {:text, "a"},
             {:key, :enter},
             {:key, :backspace},
             {:key, :ctrl_c},
             {:key, :left},
             {:key, :right}
           ]
  end

  test "holds an incomplete UTF-8 character" do
    <<first, rest::binary>> = "λ"
    {state, []} = Input.feed(%Input{}, <<first>>)
    {_state, [{:text, "λ"}]} = Input.feed(state, rest)
  end

  test "holds a split escape sequence" do
    {state, []} = Input.feed(%Input{}, "\e[")
    {_state, [{:key, :left}]} = Input.feed(state, "D")
  end

  test "flushes a single Escape key" do
    {state, []} = Input.feed(%Input{}, "\e")
    {_state, [{:key, :escape}]} = Input.flush_escape(state)
  end

  test "decodes bracketed paste split across chunks" do
    {state, []} = Input.feed(%Input{}, "\e[200~hello\e[20")
    {_state, [{:paste, "hello"}]} = Input.feed(state, "1~")
  end

  test "decodes alternate enter and backspace bytes" do
    {_state, events} = Input.feed(%Input{}, <<10, 8>>)
    assert events == [{:key, :enter}, {:key, :backspace}]
  end

  test "treats an unknown escape sequence as escape and text" do
    {_state, events} = Input.feed(%Input{}, "\eX")
    assert events == [{:key, :escape}, {:text, "X"}]
  end

  test "replaces invalid UTF-8 and holds longer partial characters" do
    {_state, [{:text, "�"}]} = Input.feed(%Input{}, <<255>>)
    {state, []} = Input.feed(%Input{}, <<0xE2>>)
    {_state, [{:text, "€"}]} = Input.feed(state, <<0x82, 0xAC>>)
    {state, []} = Input.feed(%Input{}, <<0xF0>>)
    {_state, [{:text, "😀"}]} = Input.feed(state, <<0x9F, 0x98, 0x80>>)
  end

  test "does not flush a complete state or an escape prefix" do
    state = %Input{}
    assert {^state, []} = Input.flush_escape(state)
    {state, []} = Input.feed(state, "\eO")
    assert {%Input{}, [{:key, :escape}, {:text, "O"}]} = Input.flush_escape(state)
  end
end
