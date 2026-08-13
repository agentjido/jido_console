defmodule Jido.Cli.Automation.InputSchema do
  @moduledoc "Zoi schemas for version 1 automation suite and scenario documents."

  alias Jido.Cli.Document

  @non_empty Zoi.string() |> Zoi.regex(~r/\S/)
  @string_list Zoi.array(Zoi.string())
  @string_or_list Zoi.union([Zoi.string(), @string_list])
  @assertions Zoi.map(
                %{
                  "contains" => @string_or_list |> Zoi.optional(),
                  "equals" => Zoi.string() |> Zoi.optional(),
                  "operation_called" => @string_or_list |> Zoi.optional()
                },
                unrecognized_keys: :error
              )
  @text_source Zoi.union([
                 @non_empty,
                 Zoi.map(
                   %{
                     "file" => @non_empty |> Zoi.optional(),
                     "text" => @non_empty |> Zoi.optional()
                   },
                   unrecognized_keys: :error
                 )
               ])
  @turn Zoi.map(
          %{
            "assertions" => @assertions |> Zoi.optional(),
            "context" => Zoi.json() |> Zoi.optional(),
            "id" => @non_empty |> Zoi.optional(),
            "input" => @text_source |> Zoi.optional(),
            "request" =>
              Zoi.map(
                %{
                  "context" => Zoi.json() |> Zoi.optional(),
                  "input" => @text_source
                },
                unrecognized_keys: :error
              )
              |> Zoi.optional()
          },
          unrecognized_keys: :error
        )
  @legacy_request Zoi.map(
                    %{
                      "context" => Zoi.json() |> Zoi.optional(),
                      "id" => @non_empty |> Zoi.optional(),
                      "input" => @text_source
                    },
                    unrecognized_keys: :error
                  )
  @scenario Zoi.map(
              %{
                "assertions" => @assertions |> Zoi.optional(),
                "context" => Zoi.json() |> Zoi.optional(),
                "execution_profile" => @non_empty |> Zoi.optional(),
                "id" => @non_empty,
                "request" => @legacy_request |> Zoi.optional(),
                "tags" => @string_list |> Zoi.optional(),
                "turns" => Zoi.array(@turn) |> Zoi.min(1) |> Zoi.optional()
              },
              unrecognized_keys: :error
            )
  @agent_ref Zoi.union([
               @non_empty,
               Zoi.map(
                 %{"file" => @non_empty, "key" => @non_empty |> Zoi.optional()},
                 unrecognized_keys: :error
               )
             ])
  @scenario_ref Zoi.union([
                  @non_empty,
                  Zoi.map(%{"file" => @non_empty}, unrecognized_keys: :error)
                ])
  @model_ref Zoi.union([
               @non_empty,
               Zoi.map(
                 %{
                   "generation" => Zoi.map(Zoi.string(), Zoi.json(), []) |> Zoi.optional(),
                   "key" => @non_empty |> Zoi.optional(),
                   "ref" => @non_empty |> Zoi.optional(),
                   "source" => Zoi.enum(["agent"]) |> Zoi.optional()
                 },
                 unrecognized_keys: :error
               )
             ])
  @matrix Zoi.map(
            %{"repeats" => Zoi.integer() |> Zoi.positive() |> Zoi.optional()},
            unrecognized_keys: :error
          )
  @run Zoi.map(
         %{
           "execution_profile" => @non_empty |> Zoi.optional(),
           "jobs" => Zoi.integer() |> Zoi.positive() |> Zoi.optional(),
           "limits" => Zoi.map(Zoi.string(), Zoi.json(), []) |> Zoi.optional(),
           "output" => @non_empty |> Zoi.optional()
         },
         unrecognized_keys: :error
       )
  @suite Zoi.map(
           %{
             "agents" => Zoi.array(@agent_ref) |> Zoi.min(1),
             "id" => @non_empty,
             "matrix" => @matrix |> Zoi.optional(),
             "models" => Zoi.array(@model_ref) |> Zoi.min(1) |> Zoi.optional(),
             "run" => @run |> Zoi.optional(),
             "scenarios" => Zoi.array(@scenario_ref) |> Zoi.min(1)
           },
           unrecognized_keys: :error
         )
  @suite_document Zoi.map(
                    %{"suite" => @suite, "version" => Zoi.enum([1]) |> Zoi.optional()},
                    unrecognized_keys: :error
                  )
  @scenario_document Zoi.map(
                       %{"scenario" => @scenario, "version" => Zoi.enum([1]) |> Zoi.optional()},
                       unrecognized_keys: :error
                     )

  @doc "Validates one decoded suite document."
  @spec validate_suite(term(), Path.t()) :: {:ok, map()} | {:error, term()}
  def validate_suite(value, path), do: Document.validate(@suite_document, value, {:suite, path})

  @doc "Validates one decoded scenario document."
  @spec validate_scenario(term(), Path.t()) :: {:ok, map()} | {:error, term()}
  def validate_scenario(value, path), do: Document.validate(@scenario_document, value, {:scenario, path})
end
