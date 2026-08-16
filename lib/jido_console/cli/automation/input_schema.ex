defmodule Jido.Console.Automation.InputSchema do
  @moduledoc """
  Exact schemas for version 1 automation suite and scenario documents.

  Validation also converts document source choices into tagged values. Loader
  code can then resolve a source without repeating the input grammar.
  """

  alias Jido.Console.Document

  @type text_source :: {:text, String.t()} | {:file, Path.t()}
  @type agent_ref :: {:file, Path.t(), String.t() | nil}
  @type scenario_ref :: {:file, Path.t()}

  @type model_ref ::
          {:agent, String.t() | nil}
          | {:override, String.t(), String.t() | nil, map() | nil}

  @doc "Validates and tags one decoded suite document."
  @spec validate_suite(term(), Path.t()) :: {:ok, map()} | {:error, term()}
  def validate_suite(value, path), do: Document.validate(suite_document(), value, {:suite, path})

  @doc "Validates, tags, and normalizes one decoded scenario document."
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
        "request" => request() |> Zoi.optional(),
        "tags" => string_list() |> Zoi.optional(),
        "turns" => Zoi.array(turn()) |> Zoi.min(1) |> Zoi.optional()
      },
      unrecognized_keys: :error
    )
    |> Zoi.refine({__MODULE__, :validate_scenario_form, []})
    |> Zoi.transform({__MODULE__, :normalize_scenario_form, []})
  end

  defp turn do
    Zoi.map(
      %{
        "assertions" => assertions() |> Zoi.optional(),
        "context" => Zoi.json() |> Zoi.optional(),
        "id" => non_empty() |> Zoi.optional(),
        "input" => text_source() |> Zoi.optional(),
        "request" => nested_request() |> Zoi.optional()
      },
      unrecognized_keys: :error
    )
    |> Zoi.refine({__MODULE__, :validate_turn_form, []})
    |> Zoi.transform({__MODULE__, :normalize_turn_form, []})
  end

  defp request do
    Zoi.map(
      %{
        "context" => Zoi.json() |> Zoi.optional(),
        "id" => non_empty() |> Zoi.optional(),
        "input" => text_source()
      },
      unrecognized_keys: :error
    )
  end

  defp nested_request do
    Zoi.map(
      %{
        "context" => Zoi.json() |> Zoi.optional(),
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
      non_empty() |> Zoi.transform({__MODULE__, :tag_text, []}),
      Zoi.map(%{"text" => non_empty()}, unrecognized_keys: :error)
      |> Zoi.transform({__MODULE__, :tag_text_map, []}),
      Zoi.map(%{"file" => non_empty()}, unrecognized_keys: :error)
      |> Zoi.transform({__MODULE__, :tag_file_map, []})
    ])
  end

  defp agent_ref do
    Zoi.union([
      non_empty() |> Zoi.transform({__MODULE__, :tag_agent_path, []}),
      Zoi.map(
        %{"file" => non_empty(), "key" => non_empty() |> Zoi.optional()},
        unrecognized_keys: :error
      )
      |> Zoi.transform({__MODULE__, :tag_agent_map, []})
    ])
  end

  defp scenario_ref do
    Zoi.union([
      non_empty() |> Zoi.transform({__MODULE__, :tag_scenario_path, []}),
      Zoi.map(%{"file" => non_empty()}, unrecognized_keys: :error)
      |> Zoi.transform({__MODULE__, :tag_scenario_map, []})
    ])
  end

  defp model_ref do
    key = non_empty() |> Zoi.optional()

    Zoi.union([
      non_empty() |> Zoi.transform({__MODULE__, :tag_model_override_path, []}),
      Zoi.map(
        %{"key" => key, "source" => Zoi.literal("agent")},
        unrecognized_keys: :error
      )
      |> Zoi.transform({__MODULE__, :tag_agent_model, []}),
      Zoi.map(
        %{
          "generation" => Zoi.map(Zoi.string(), Zoi.json(), []) |> Zoi.optional(),
          "key" => key,
          "ref" => non_empty()
        },
        unrecognized_keys: :error
      )
      |> Zoi.transform({__MODULE__, :tag_override_model, []})
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

  @doc false
  @spec validate_scenario_form(map(), term()) :: :ok | {:error, String.t()}
  def validate_scenario_form(scenario, _opts) do
    turns? = Map.has_key?(scenario, "turns")
    request? = Map.has_key?(scenario, "request")

    cond do
      turns? and request? ->
        {:error, "must contain turns or request, not both"}

      not turns? and not request? ->
        {:error, "must contain turns or request"}

      turns? and Map.has_key?(scenario, "assertions") ->
        {:error, "top-level assertions require the request form"}

      true ->
        :ok
    end
  end

  @doc false
  @spec normalize_scenario_form(map(), term()) :: {:ok, map()}
  def normalize_scenario_form(%{"request" => request} = scenario, _opts) do
    turn = maybe_put(request, "assertions", Map.get(scenario, "assertions"))

    {:ok,
     scenario
     |> Map.drop(["assertions", "request"])
     |> Map.put("turns", [turn])}
  end

  def normalize_scenario_form(scenario, _opts), do: {:ok, scenario}

  @doc false
  @spec validate_turn_form(map(), term()) :: :ok | {:error, String.t()}
  def validate_turn_form(turn, _opts) do
    input? = Map.has_key?(turn, "input")
    request? = Map.has_key?(turn, "request")

    cond do
      input? and request? ->
        {:error, "must contain input or request, not both"}

      not input? and not request? ->
        {:error, "must contain input or request"}

      request? and Map.has_key?(turn, "context") ->
        {:error, "nested request context must be inside request"}

      true ->
        :ok
    end
  end

  @doc false
  @spec normalize_turn_form(map(), term()) :: {:ok, map()}
  def normalize_turn_form(%{"request" => request} = turn, _opts) do
    {:ok,
     turn
     |> Map.delete("request")
     |> Map.put("input", Map.fetch!(request, "input"))
     |> maybe_put("context", Map.get(request, "context"))}
  end

  def normalize_turn_form(turn, _opts), do: {:ok, turn}

  @doc false
  @spec tag_text(String.t(), term()) :: {:ok, text_source()}
  def tag_text(text, _opts), do: {:ok, {:text, text}}

  @doc false
  @spec tag_text_map(%{required(String.t()) => String.t()}, term()) :: {:ok, text_source()}
  def tag_text_map(%{"text" => text}, _opts), do: {:ok, {:text, text}}

  @doc false
  @spec tag_file_map(%{required(String.t()) => String.t()}, term()) :: {:ok, text_source()}
  def tag_file_map(%{"file" => file}, _opts), do: {:ok, {:file, file}}

  @doc false
  @spec tag_agent_path(Path.t(), term()) :: {:ok, agent_ref()}
  def tag_agent_path(file, _opts), do: {:ok, {:file, file, nil}}

  @doc false
  @spec tag_agent_map(map(), term()) :: {:ok, agent_ref()}
  def tag_agent_map(%{"file" => file} = agent, _opts),
    do: {:ok, {:file, file, Map.get(agent, "key")}}

  @doc false
  @spec tag_scenario_path(Path.t(), term()) :: {:ok, scenario_ref()}
  def tag_scenario_path(file, _opts), do: {:ok, {:file, file}}

  @doc false
  @spec tag_scenario_map(%{required(String.t()) => String.t()}, term()) :: {:ok, scenario_ref()}
  def tag_scenario_map(%{"file" => file}, _opts), do: {:ok, {:file, file}}

  @doc false
  @spec tag_model_override_path(String.t(), term()) :: {:ok, model_ref()}
  def tag_model_override_path(ref, _opts), do: {:ok, {:override, ref, nil, nil}}

  @doc false
  @spec tag_agent_model(map(), term()) :: {:ok, model_ref()}
  def tag_agent_model(model, _opts), do: {:ok, {:agent, Map.get(model, "key")}}

  @doc false
  @spec tag_override_model(map(), term()) :: {:ok, model_ref()}
  def tag_override_model(%{"ref" => ref} = model, _opts),
    do: {:ok, {:override, ref, Map.get(model, "key"), Map.get(model, "generation")}}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp string_or_list, do: Zoi.union([Zoi.string(), string_list()])
  defp string_list, do: Zoi.array(Zoi.string())
  defp non_empty, do: Document.non_empty_string()
end
