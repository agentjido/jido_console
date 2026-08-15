defmodule Jido.Console.InteractiveOptions do
  @moduledoc "Validated interactive command options."

  @schema Zoi.map(
            %{
              coding_pack: Zoi.string() |> Zoi.optional(),
              coding_profile: Zoi.string() |> Zoi.optional(),
              help: Zoi.boolean() |> Zoi.optional(),
              model: Zoi.string() |> Zoi.optional(),
              project_root: Zoi.string() |> Zoi.optional(),
              version: Zoi.boolean() |> Zoi.optional()
            },
            unrecognized_keys: :error
          )

  @doc "Validates options returned by `OptionParser`."
  @spec parse(keyword()) :: {:ok, map()} | {:error, term()}
  def parse(options) when is_list(options) do
    case Zoi.parse(@schema, Map.new(options)) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, errors} -> {:error, {:invalid_interactive_options, Zoi.treefy_errors(errors)}}
    end
  end
end
