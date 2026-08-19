defmodule Jido.Console.Storage.CanonicalJSONTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Storage.CanonicalJSON

  test "equivalent maps have identical recursive canonical bytes" do
    first = %{"z" => 1, "a" => %{"z" => 2, "a" => [3, %{"b" => 2, "a" => 1}]}}
    second = Map.new(Enum.reverse(Map.to_list(first)))

    assert {:ok, bytes} = CanonicalJSON.encode(first)
    assert {:ok, ^bytes} = CanonicalJSON.encode(second)
    assert bytes == ~s({"a":{"a":[3,{"a":1,"b":2}],"z":2},"z":1})
    assert {:ok, ^first} = CanonicalJSON.decode(bytes)
  end

  test "noncanonical and non-JSON values fail before bytes are accepted" do
    assert {:error, :noncanonical_json} = CanonicalJSON.decode(~s({"z":1,"a":2}))
    assert {:error, {:invalid_json, _reason}} = CanonicalJSON.decode("{")
    assert {:error, :invalid_json_bytes} = CanonicalJSON.decode(:not_bytes)
    assert {:error, {:forbidden_runtime_value, :pid}} = CanonicalJSON.encode(%{"pid" => self()})
    assert {:error, :non_string_json_key} = CanonicalJSON.encode(%{atom: true})

    for {value, reason} <- [
          {%URI{}, {:forbidden_runtime_value, :struct}},
          {make_ref(), {:forbidden_runtime_value, :reference}},
          {fn -> :ok end, {:forbidden_runtime_value, :function}},
          {:atom, :non_json_value},
          {{:tuple}, :non_json_value}
        ] do
      assert {:error, ^reason} = CanonicalJSON.encode(value)
    end

    assert {:error, :non_string_json_key} = CanonicalJSON.encode([%{1 => "invalid"}])
  end
end
