defmodule Jido.Console.Terminal.InputTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Terminal.Input

  test "decodes text, control keys, and navigation sequences" do
    {_state, events} = Input.feed(%Input{}, "a\r\n\x7f\x03\e[A\e[B\e[D\e[C\e[5~\e[6~")

    assert events == [
             {:text, "a"},
             {:key, :enter},
             {:key, :newline},
             {:key, :backspace},
             {:key, :ctrl_c},
             {:key, :up},
             {:key, :down},
             {:key, :left},
             {:key, :right},
             {:key, :page_up},
             {:key, :page_down}
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

  test "decodes newline and alternate backspace bytes" do
    {_state, events} = Input.feed(%Input{}, <<10, 8>>)
    assert events == [{:key, :newline}, {:key, :backspace}]
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
