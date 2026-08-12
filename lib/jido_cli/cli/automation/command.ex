defmodule Jido.Cli.Automation.Command do
  @moduledoc "Parses automated run and eval commands."

  @type t ::
          %{
            required(:name) => :run,
            required(:agent) => String.t(),
            optional(:input) => String.t(),
            optional(:scenario) => String.t(),
            optional(:model) => String.t(),
            optional(:output) => String.t(),
            optional(:runtime_profile) => String.t()
          }
          | %{
              required(:name) => :eval,
              required(:suite) => String.t(),
              optional(:jobs) => pos_integer(),
              optional(:output) => String.t()
            }

  @doc "Parses a run or eval command."
  @spec parse([String.t()]) :: {:ok, t()} | {:error, term()}
  def parse(["run" | args]), do: parse_run(args)
  def parse(["eval" | args]), do: parse_eval(args)
  def parse(args), do: {:error, {:unknown_automation_command, args}}

  defp parse_run(args) do
    switches = [
      agent: :string,
      input: :string,
      scenario: :string,
      model: :string,
      output: :string,
      runtime_profile: :string
    ]

    case OptionParser.parse(args, strict: switches, aliases: [a: :agent, i: :input, o: :output]) do
      {options, [], []} -> build_run(options)
      {_options, positional, []} -> {:error, {:unexpected_arguments, positional}}
      {_options, _positional, invalid} -> {:error, {:invalid_options, invalid}}
    end
  end

  defp build_run(options) do
    agent = Keyword.get(options, :agent)
    input = Keyword.get(options, :input)
    scenario = Keyword.get(options, :scenario)

    cond do
      not present?(agent) ->
        {:error, :missing_agent}

      present?(input) == present?(scenario) ->
        {:error, :choose_one_input_or_scenario}

      true ->
        command =
          options
          |> Map.new()
          |> Map.put(:name, :run)

        {:ok, command}
    end
  end

  defp parse_eval(args) do
    switches = [jobs: :integer, output: :string]

    case OptionParser.parse(args, strict: switches, aliases: [j: :jobs, o: :output]) do
      {options, [suite], []} -> build_eval(suite, options)
      {_options, [], []} -> {:error, :missing_suite}
      {_options, positional, []} -> {:error, {:unexpected_arguments, positional}}
      {_options, _positional, invalid} -> {:error, {:invalid_options, invalid}}
    end
  end

  defp build_eval(suite, options) do
    case Keyword.get(options, :jobs) do
      jobs when is_integer(jobs) and jobs <= 0 ->
        {:error, {:invalid_jobs, jobs}}

      _jobs ->
        command =
          options
          |> Map.new()
          |> Map.merge(%{name: :eval, suite: suite})

        {:ok, command}
    end
  end

  defp present?(value), do: is_binary(value) and value != ""
end
