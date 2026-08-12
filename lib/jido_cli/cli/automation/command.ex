defmodule Jido.Cli.Automation.Command do
  @moduledoc """
  Parses and validates automated `run` and `eval` commands.

  The command is modelled as a Zoi struct so the field shape and types are
  declared once. Cross-field rules that Zoi cannot express (an `--agent` is
  required for `run`, `--input` and `--scenario` are mutually exclusive, and
  `--jobs` must be positive) are checked in `new/1` and return the same reason
  terms the rest of the pipeline expects.
  """

  alias Jido.Cli.Automation.Command

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.enum([:run, :eval]),
              agent: Zoi.string() |> Zoi.nullish(),
              input: Zoi.string() |> Zoi.nullish(),
              scenario: Zoi.string() |> Zoi.nullish(),
              model: Zoi.string() |> Zoi.nullish(),
              output: Zoi.string() |> Zoi.nullish(),
              runtime_profile: Zoi.string() |> Zoi.nullish(),
              suite: Zoi.string() |> Zoi.nullish(),
              jobs: Zoi.integer() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for this command."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Parses a run or eval command."
  @spec parse([String.t()]) :: {:ok, Command.t()} | {:error, term()}
  def parse(["run" | args]), do: parse_run(args)
  def parse(["eval" | args]), do: parse_eval(args)
  def parse(args), do: {:error, {:unknown_automation_command, args}}

  @doc """
  Builds and validates a command from a map of attributes.

  Zoi validates the field types; the cross-field rules are then checked and
  return the reason terms the pipeline relies on.
  """
  @spec new(map()) :: {:ok, Command.t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, %Command{} = command} <- Zoi.parse(@schema, attrs),
         {:ok, %Command{} = valid} <- validate(command) do
      {:ok, valid}
    end
  end

  @doc "Like `new/1` but raises on validation errors."
  @spec new!(map()) :: Command.t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, command} -> command
      {:error, reason} -> raise ArgumentError, "invalid Jido.Cli command: #{inspect(reason)}"
    end
  end

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
      {options, [], []} ->
        options
        |> Map.new()
        |> Map.put(:name, :run)
        |> new()

      {_options, positional, []} ->
        {:error, {:unexpected_arguments, positional}}

      {_options, _positional, invalid} ->
        {:error, {:invalid_options, invalid}}
    end
  end

  defp parse_eval(args) do
    switches = [jobs: :integer, output: :string, runtime_profile: :string]

    case OptionParser.parse(args, strict: switches, aliases: [j: :jobs, o: :output]) do
      {options, [suite], []} ->
        options
        |> Map.new()
        |> Map.merge(%{name: :eval, suite: suite})
        |> new()

      {_options, [], []} ->
        {:error, :missing_suite}

      {_options, positional, []} ->
        {:error, {:unexpected_arguments, positional}}

      {_options, _positional, invalid} ->
        {:error, {:invalid_options, invalid}}
    end
  end

  defp validate(%Command{name: :run} = command) do
    cond do
      blank?(command.agent) -> {:error, :missing_agent}
      present?(command.input) == present?(command.scenario) -> {:error, :choose_one_input_or_scenario}
      command.runtime_profile == "" -> {:error, {:invalid_execution_profile, ""}}
      true -> {:ok, command}
    end
  end

  defp validate(%Command{name: :eval} = command) do
    cond do
      is_integer(command.jobs) and command.jobs <= 0 -> {:error, {:invalid_jobs, command.jobs}}
      command.runtime_profile == "" -> {:error, {:invalid_execution_profile, ""}}
      true -> {:ok, command}
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(value) when is_binary(value), do: true

  defp blank?(value), do: not present?(value)
end
