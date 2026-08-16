defmodule Jido.Console.SourceConventionsTest do
  use ExUnit.Case, async: true

  @source_files Path.wildcard("lib/**/*.ex")

  test "all explicit production structs derive their shape from Zoi" do
    violations =
      Enum.flat_map(@source_files, fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, number} ->
          if Regex.match?(~r/^\s*defstruct\b/, line) and
               not String.contains?(line, "defstruct Zoi.Struct.struct_fields(") do
            ["#{path}:#{number}"]
          else
            []
          end
        end)
      end)

    assert violations == [],
           "explicit structs must derive fields and defaults from a Zoi schema:\n" <>
             Enum.join(violations, "\n")
  end

  test "production source does not define a parallel exception taxonomy" do
    violations =
      Enum.filter(@source_files, fn path ->
        Regex.match?(~r/^\s*defexception\b/m, File.read!(path))
      end)

    assert violations == [],
           "project exceptions must use Jido.Console.Error and Splode:\n" <>
             Enum.join(violations, "\n")
  end
end
