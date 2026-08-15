defmodule Jido.Console.Automation.InputSchema do
  @moduledoc "Zoi schemas for version 1 automation suite and scenario documents."

  alias Jido.Console.Document

  @doc "Validates one decoded suite document."
  @spec validate_suite(term(), Path.t()) :: {:ok, map()} | {:error, term()}
  def validate_suite(value, path), do: Document.validate(suite_document(), value, {:suite, path})

  @doc "Validates one decoded scenario document."
  @spec validate_scenario(term(), Path.t()) :: {:ok, map()} | {:error, term()}
  def validate_scenario(value, path), do: Document.validate(scenario_document(), value, {:scenario, path})

  defp suite_document do
    Zoi.map(
      %{"suite" => suite(), "version" => Zoi.enum([1]) |> Zoi.optional()},
      unrecognized_keys: :error
    )
  end

  defp scenario_document do
    Zoi.map(
      %{"scenario" => scenario(), "version" => Zoi.enum([1]) |> Zoi.optional()},
      unrecognized_keys: :error
    )
  end

  defp suite do
    Zoi.map(
      %{
        "agents" => Zoi.array(agent_ref()) |> Zoi.min(1),
        "id" => non_empty(),
        "matrix" => matrix() |> Zoi.optional(),
        "models" => Zoi.array(model_ref()) |> Zoi.min(1) |> Zoi.optional(),
        "run" => run() |> Zoi.optional(),
        "scenarios" => Zoi.array(scenario_ref()) |> Zoi.min(1)
      },
      unrecognized_keys: :error
    )
  end

  defp scenario do
    Zoi.map(
      %{
        "assertions" => assertions() |> Zoi.optional(),
        "context" => Zoi.json() |> Zoi.optional(),
        "execution_profile" => non_empty() |> Zoi.optional(),
        "id" => non_empty(),
        "request" => legacy_request() |> Zoi.optional(),
        "tags" => string_list() |> Zoi.optional(),
        "turns" => Zoi.array(turn()) |> Zoi.min(1) |> Zoi.optional()
      },
      unrecognized_keys: :error
    )
  end

  defp turn do
    Zoi.map(
      %{
        "assertions" => assertions() |> Zoi.optional(),
        "context" => Zoi.json() |> Zoi.optional(),
        "id" => non_empty() |> Zoi.optional(),
        "input" => text_source() |> Zoi.optional(),
        "request" =>
          Zoi.map(
            %{
              "context" => Zoi.json() |> Zoi.optional(),
              "input" => text_source()
            },
            unrecognized_keys: :error
          )
          |> Zoi.optional()
      },
      unrecognized_keys: :error
    )
  end

  defp legacy_request do
    Zoi.map(
      %{
        "context" => Zoi.json() |> Zoi.optional(),
        "id" => non_empty() |> Zoi.optional(),
        "input" => text_source()
      },
      unrecognized_keys: :error
    )
  end

  defp assertions do
    Zoi.map(
      %{
        "contains" => string_or_list() |> Zoi.optional(),
        "equals" => Zoi.string() |> Zoi.optional(),
        "operation_called" => string_or_list() |> Zoi.optional()
      },
      unrecognized_keys: :error
    )
  end

  defp text_source do
    Zoi.union([
      non_empty(),
      Zoi.map(
        %{
          "file" => non_empty() |> Zoi.optional(),
          "text" => non_empty() |> Zoi.optional()
        },
        unrecognized_keys: :error
      )
    ])
  end

  defp agent_ref do
    Zoi.union([
      non_empty(),
      Zoi.map(
        %{"file" => non_empty(), "key" => non_empty() |> Zoi.optional()},
        unrecognized_keys: :error
      )
    ])
  end

  defp scenario_ref do
    Zoi.union([
      non_empty(),
      Zoi.map(%{"file" => non_empty()}, unrecognized_keys: :error)
    ])
  end

  defp model_ref do
    Zoi.union([
      non_empty(),
      Zoi.map(
        %{
          "generation" => Zoi.map(Zoi.string(), Zoi.json(), []) |> Zoi.optional(),
          "key" => non_empty() |> Zoi.optional(),
          "ref" => non_empty() |> Zoi.optional(),
          "source" => Zoi.enum(["agent"]) |> Zoi.optional()
        },
        unrecognized_keys: :error
      )
    ])
  end

  defp matrix do
    Zoi.map(
      %{"repeats" => Zoi.integer() |> Zoi.positive() |> Zoi.optional()},
      unrecognized_keys: :error
    )
  end

  defp run do
    Zoi.map(
      %{
        "execution_profile" => non_empty() |> Zoi.optional(),
        "jobs" => Zoi.integer() |> Zoi.positive() |> Zoi.optional(),
        "limits" => Zoi.map(Zoi.string(), Zoi.json(), []) |> Zoi.optional(),
        "output" => non_empty() |> Zoi.optional()
      },
      unrecognized_keys: :error
    )
  end

  defp string_or_list, do: Zoi.union([Zoi.string(), string_list()])
  defp string_list, do: Zoi.array(Zoi.string())
  defp non_empty, do: Document.non_empty_string()
end
