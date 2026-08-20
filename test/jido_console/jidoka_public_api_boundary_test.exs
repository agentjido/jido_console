defmodule Jido.Console.JidokaPublicApiBoundaryTest do
  use ExUnit.Case, async: true

  defmodule BoundaryScanner do
    @moduledoc false

    @public_facades [
      "Jidoka",
      "Jidoka.Agent",
      "Jidoka.Session"
    ]

    @public_contract_prefixes [
      "Jidoka.Agent.Spec",
      "Jidoka.Cancellation",
      "Jidoka.Chat.Request",
      "Jidoka.CodingPack",
      "Jidoka.Effect",
      "Jidoka.Event",
      "Jidoka.Id",
      "Jidoka.ExecutionEnvironment",
      "Jidoka.Extension",
      "Jidoka.Operation.Source",
      "Jidoka.Policy",
      "Jidoka.Replay",
      "Jidoka.Review",
      "Jidoka.Runtime.Limits",
      "Jidoka.Stream",
      "Jidoka.Turn"
    ]

    @public_contract_modules [
      "Jidoka.Session.Data",
      "Jidoka.Session.Environment",
      "Jidoka.Session.Lease",
      "Jidoka.Session.Lineage",
      "Jidoka.Session.Replay",
      "Jidoka.Session.Sequence",
      "Jidoka.Session.Sequence.Request",
      "Jidoka.Session.Store",
      "Jidoka.Session.Transitions",
      "Jidoka.Snapshot"
    ]

    @transition_functions ~w(put claim resume recover checkpoint commit renew recoverable?)a
    @private_store_helpers ~w(
      put_transition
      claim_transition
      resume_transition
      recover_transition
      checkpoint_transition
      commit_transition
      renew_transition
    )a

    @approved_support_prefixes [
      "Jidoka.Config",
      "Jidoka.Error",
      "Jidoka.Eval"
    ]

    @forbidden_prefixes [
      "Jidoka.Adapter",
      "Jidoka.Chat.Async",
      "Jidoka.Harness",
      "Jidoka.Projection",
      "Jidoka.Runtime"
    ]

    def audit_file(path) do
      path
      |> File.read!()
      |> audit_source(path)
    end

    def audit_source(source, source_name \\ "fixture.ex") do
      case Code.string_to_quoted(source, columns: true) do
        {:ok, ast} ->
          {_ast, violations} = Macro.prewalk(ast, [], &inspect_node/2)
          Enum.reverse(violations)

        {:error, {location, error, token}} ->
          [
            violation(
              source_name,
              Keyword.get(location, :line, 1),
              "cannot parse source: #{to_string(error)}#{to_string(token)}"
            )
          ]
      end
      |> Enum.map(&Map.put(&1, :source, source_name))
    end

    defp inspect_node({:__aliases__, meta, parts} = node, violations) do
      case jidoka_module(parts) do
        nil ->
          {node, violations}

        module ->
          case module_violation(module) do
            nil -> {node, violations}
            reason -> {node, [violation(nil, meta[:line], reason) | violations]}
          end
      end
    end

    defp inspect_node(
           {{:., meta, [{:__aliases__, _, [:Task]}, :shutdown]}, _, _} = node,
           violations
         ) do
      {node, [violation(nil, meta[:line], "Task.shutdown/2 cannot own Jidoka requests") | violations]}
    end

    defp inspect_node(
           {{:., meta, [{:__aliases__, _, parts}, function]}, _, _arguments} = node,
           violations
         )
         when is_atom(function) do
      module = jidoka_module(parts)

      case function_violation(module, function) do
        nil -> {node, violations}
        reason -> {node, [violation(nil, meta[:line], reason) | violations]}
      end
    end

    defp inspect_node(
           {:%, meta,
            [
              {:__aliases__, _, [:Jidoka, :Chat, :Request]},
              {:%{}, _, fields}
            ]} = node,
           violations
         ) do
      if Keyword.has_key?(fields, :task) do
        {node,
         [
           violation(nil, meta[:line], "Jidoka.Chat.Request task ownership is internal")
           | violations
         ]}
      else
        {node, violations}
      end
    end

    defp inspect_node(node, violations), do: {node, violations}

    defp jidoka_module([:Jidoka | _] = parts), do: Enum.map_join(parts, ".", &Atom.to_string/1)
    defp jidoka_module(_parts), do: nil

    defp module_violation(module) do
      cond do
        execution_module?(module) ->
          "forbidden Jidoka execution module: #{module}"

        approved_module?(module) ->
          nil

        forbidden_module?(module) ->
          "forbidden Jidoka implementation module: #{module}"

        true ->
          "Jidoka module is not in the public client allow-list: #{module}"
      end
    end

    defp forbidden_module?(module) do
      Enum.any?(@forbidden_prefixes, &module_in_prefix?(module, &1))
    end

    defp execution_module?(module) do
      module
      |> String.split(".")
      |> Enum.member?("Execution")
    end

    defp approved_module?(module) do
      module in @public_facades or
        module in @public_contract_modules or
        Enum.any?(@public_contract_prefixes, &module_in_prefix?(module, &1)) or
        Enum.any?(@approved_support_prefixes, &module_in_prefix?(module, &1))
    end

    defp function_violation("Jidoka.Session.Transitions", function)
         when function not in @transition_functions,
         do: "Jidoka.Session.Transitions function is not approved: #{function}"

    defp function_violation("Jidoka.Session.Store", function) when function in @private_store_helpers,
      do: "private Jidoka.Session.Store transition helper: #{function}"

    defp function_violation(_module, _function), do: nil

    defp module_in_prefix?(module, prefix) do
      module == prefix or String.starts_with?(module, prefix <> ".")
    end

    defp violation(source, line, reason) do
      %{source: source, line: line || 1, reason: reason}
    end
  end

  test "production source uses only the public Jidoka client boundary" do
    violations =
      "lib/jido_console/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(&BoundaryScanner.audit_file/1)

    assert violations == [], format_violations(violations)
  end

  test "rejects forbidden aliases and remote calls" do
    violations =
      BoundaryScanner.audit_source("""
      defmodule BoundaryViolation do
        alias Jidoka.Runtime.Capabilities

        def call(input), do: Jidoka.Adapter.ReqLLM.call(input)
      end
      """)

    assert Enum.any?(violations, &String.contains?(&1.reason, "Jidoka.Runtime.Capabilities"))
    assert Enum.any?(violations, &String.contains?(&1.reason, "Jidoka.Adapter.ReqLLM"))
  end

  test "rejects request task ownership and direct task shutdown" do
    violations =
      BoundaryScanner.audit_source("""
      defmodule TaskOwnershipViolation do
        def cancel(%Jidoka.Chat.Request{task: task}) do
          Task.shutdown(task, :brutal_kill)
        end
      end
      """)

    assert Enum.any?(violations, &String.contains?(&1.reason, "task ownership is internal"))
    assert Enum.any?(violations, &String.contains?(&1.reason, "Task.shutdown/2"))
  end

  test "rejects execution modules" do
    [violation | _] =
      BoundaryScanner.audit_source("alias Jidoka.Session.Execution")

    assert violation.reason =~ "forbidden Jidoka execution module"
  end

  test "rejects private durability modules and helper functions" do
    violations =
      BoundaryScanner.audit_source("""
      defmodule PrivateDurabilityViolation do
        def decode(value), do: Jidoka.Snapshot.Codec.deserialize(value)
        def claim(session, request, opts), do: Jidoka.Session.Store.claim_transition(session, request, opts)
        def unknown(session), do: Jidoka.Session.Transitions.undocumented(session)
      end
      """)

    assert Enum.any?(violations, &String.contains?(&1.reason, "Jidoka.Snapshot.Codec"))
    assert Enum.any?(violations, &String.contains?(&1.reason, "private Jidoka.Session.Store"))
    assert Enum.any?(violations, &String.contains?(&1.reason, "function is not approved"))
  end

  test "production source has no undocumented durable checkpoint hook" do
    matches =
      "lib/jido_console/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        source = File.read!(path)
        source =~ ":on_durable_checkpoint" or source =~ "on_durable_checkpoint:"
      end)

    assert matches == []
  end

  test "reports malformed source without crashing" do
    assert [%{line: 1, reason: "cannot parse source:" <> _}] =
             BoundaryScanner.audit_source("defmodule Broken do")
  end

  defp format_violations(violations) do
    Enum.map_join(violations, "\n", fn violation ->
      "#{violation.source}:#{violation.line}: #{violation.reason}"
    end)
  end
end
