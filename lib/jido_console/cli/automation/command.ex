defmodule Jido.Console.Automation.Command do
  @moduledoc """
  Parses and validates automated `run` and `eval` commands.

  A parsed command is an exact `Run` or `Eval` value. `Run` owns one tagged
  input source, and `Eval` owns one suite. The representation cannot contain
  fields from the other command or both run input forms.

  Zoi validates field types. Cross-field rules return the documented reason
  terms that the automation pipeline expects.
  """

  defmodule Run do
    @moduledoc "A validated `run` command with exactly one input source."

    @schema Zoi.struct(
              __MODULE__,
              %{
                agent: Zoi.string(),
                source:
                  Zoi.union([
                    Zoi.tuple({Zoi.literal(:input), Zoi.string()}),
                    Zoi.tuple({Zoi.literal(:scenario), Zoi.string()})
                  ]),
                model: Zoi.string() |> Zoi.nullish(),
                output: Zoi.string() |> Zoi.nullish(),
                runtime_profile: Zoi.string() |> Zoi.nullish()
              },
              unrecognized_keys: :error
            )

    @enforce_keys Zoi.Struct.enforce_keys(@schema)
    defstruct Zoi.Struct.struct_fields(@schema)

    @type source :: {:input, String.t()} | {:scenario, String.t()}
    @type t :: %__MODULE__{
            agent: String.t(),
            source: source(),
            model: String.t() | nil,
            output: String.t() | nil,
            runtime_profile: String.t() | nil
          }

    @doc false
    @spec schema() :: Zoi.schema()
    def schema, do: @schema
  end

  defmodule Eval do
    @moduledoc "A validated `eval` command for one suite."

    @schema Zoi.struct(
              __MODULE__,
              %{
                suite: Zoi.string(),
                jobs: Zoi.integer() |> Zoi.nullish(),
                output: Zoi.string() |> Zoi.nullish(),
                runtime_profile: Zoi.string() |> Zoi.nullish()
              },
              unrecognized_keys: :error
            )

    @enforce_keys Zoi.Struct.enforce_keys(@schema)
    defstruct Zoi.Struct.struct_fields(@schema)

    @type t :: %__MODULE__{
            suite: String.t(),
            jobs: pos_integer() | nil,
            output: String.t() | nil,
            runtime_profile: String.t() | nil
          }

    @doc false
    @spec schema() :: Zoi.schema()
    def schema, do: @schema
  end

  alias __MODULE__.{Eval, Run}

  @run_attrs_schema Zoi.map(
                      %{
                        name: Zoi.literal(:run),
                        agent: Zoi.string() |> Zoi.nullish(),
                        input: Zoi.string() |> Zoi.nullish(),
                        scenario: Zoi.string() |> Zoi.nullish(),
                        model: Zoi.string() |> Zoi.nullish(),
                        output: Zoi.string() |> Zoi.nullish(),
                        runtime_profile: Zoi.string() |> Zoi.nullish()
                      },
                      coerce: true,
                      unrecognized_keys: :error
                    )

  @eval_attrs_schema Zoi.map(
                       %{
                         name: Zoi.literal(:eval),
                         suite: Zoi.string() |> Zoi.nullish(),
                         jobs: Zoi.integer() |> Zoi.nullish(),
                         output: Zoi.string() |> Zoi.nullish(),
                         runtime_profile: Zoi.string() |> Zoi.nullish()
                       },
                       coerce: true,
                       unrecognized_keys: :error
                     )

  @schema Zoi.union([Run.schema(), Eval.schema()])

  @type t :: Run.t() | Eval.t()

  @doc "Returns the Zoi schema for validated command variants."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Parses a run or eval command."
  @spec parse([String.t()]) :: {:ok, t()} | {:error, term()}
  def parse(["run" | args]), do: parse_run(args)
  def parse(["eval" | args]), do: parse_eval(args)
  def parse(args), do: {:error, {:unknown_automation_command, args}}

  @doc """
  Builds and validates an exact command variant from parser attributes.

  Attributes for the other command variant are rejected. A run must select
  exactly one input source, and an eval must select one suite.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    case command_name(attrs) do
      :run -> new_run(attrs)
      :eval -> new_eval(attrs)
      _other -> Zoi.parse(Zoi.union([@run_attrs_schema, @eval_attrs_schema]), attrs)
    end
  end

  @doc "Like `new/1` but raises on validation errors."
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, command} -> command
      {:error, reason} -> raise ArgumentError, "invalid Jido.Console command: #{inspect(reason)}"
    end
  end

  @doc "Returns the stable semantic data used to digest a command."
  @spec digest_projection(t()) :: map()
  def digest_projection(%Run{} = command) do
    {source_kind, source_path} = command.source

    %{
      name: :run,
      agent: command.agent,
      source: %{kind: source_kind, path: source_path},
      model: command.model,
      output: command.output,
      runtime_profile: command.runtime_profile
    }
  end

  def digest_projection(%Eval{} = command) do
    %{
      name: :eval,
      suite: command.suite,
      jobs: command.jobs,
      output: command.output,
      runtime_profile: command.runtime_profile
    }
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

  defp new_run(attrs) do
    with {:ok, attrs} <- Zoi.parse(@run_attrs_schema, attrs),
         :ok <- validate_run(attrs) do
      source =
        if present?(Map.get(attrs, :input)),
          do: {:input, Map.fetch!(attrs, :input)},
          else: {:scenario, Map.fetch!(attrs, :scenario)}

      {:ok,
       %Run{
         agent: Map.fetch!(attrs, :agent),
         source: source,
         model: Map.get(attrs, :model),
         output: Map.get(attrs, :output),
         runtime_profile: Map.get(attrs, :runtime_profile)
       }}
    end
  end

  defp new_eval(attrs) do
    with {:ok, attrs} <- Zoi.parse(@eval_attrs_schema, attrs),
         :ok <- validate_eval(attrs) do
      {:ok,
       %Eval{
         suite: Map.fetch!(attrs, :suite),
         jobs: Map.get(attrs, :jobs),
         output: Map.get(attrs, :output),
         runtime_profile: Map.get(attrs, :runtime_profile)
       }}
    end
  end

  defp validate_run(attrs) do
    cond do
      blank?(Map.get(attrs, :agent)) ->
        {:error, :missing_agent}

      present?(Map.get(attrs, :input)) == present?(Map.get(attrs, :scenario)) ->
        {:error, :choose_one_input_or_scenario}

      Map.get(attrs, :runtime_profile) == "" ->
        {:error, {:invalid_execution_profile, ""}}

      true ->
        :ok
    end
  end

  defp validate_eval(attrs) do
    cond do
      blank?(Map.get(attrs, :suite)) ->
        {:error, :missing_suite}

      is_integer(Map.get(attrs, :jobs)) and Map.fetch!(attrs, :jobs) <= 0 ->
        {:error, {:invalid_jobs, Map.fetch!(attrs, :jobs)}}

      Map.get(attrs, :runtime_profile) == "" ->
        {:error, {:invalid_execution_profile, ""}}

      true ->
        :ok
    end
  end

  defp command_name(attrs), do: Map.get(attrs, :name) || Map.get(attrs, "name")

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(value) when is_binary(value), do: true

  defp blank?(value), do: not present?(value)
end
