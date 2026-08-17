defmodule Jido.Console.Session.Client.Boundary do
  @moduledoc """
  Syntax guard for production session client adapters.

  The guard rejects direct session-owner access, raw runtime messages, and the
  deleted TUI compatibility path. It reads quoted Elixir syntax, so comments
  and documentation cannot hide or create a violation.
  """

  @forbidden_module_suffixes [
    "Jido.Console.Session.Server",
    "Jido.Console.Session.Delivery",
    "Jido.Console.Session.Recovery",
    "Jidoka.Session",
    "Jidoka.Event",
    "Jido.Console.Runtime.Result",
    "Jido.Console.Tui.EventProjection",
    "Session.Server",
    "Session.Delivery",
    "Session.Recovery",
    "Runtime.Result",
    "EventProjection"
  ]

  @raw_client_tags [
    :jidoka,
    :session_updated,
    :session_gap,
    :session_runtime_event,
    :session_runtime_started,
    :session_runtime_result,
    :session_runtime_error,
    :session_control_result
  ]

  @legacy_functions [:broadcast_runtime, :legacy_ack]

  @type violation :: %{
          required(:path) => String.t(),
          required(:line) => non_neg_integer(),
          required(:kind) => atom(),
          required(:subject) => term()
        }

  @doc "Checks adapter source paths for direct internal session access."
  @spec check([String.t()], String.t()) :: :ok | {:error, term()}
  def check(paths, root \\ File.cwd!()) do
    case violations(paths, root) do
      [] -> :ok
      [violation | _rest] -> {:error, {:client_boundary_bypass, violation}}
    end
  end

  @doc "Returns syntax violations in production client paths."
  @spec violations([String.t()], String.t()) :: [violation()]
  def violations(paths, root \\ File.cwd!()) do
    scan(paths, root, &client_violation/1)
  end

  @doc "Returns deleted compatibility-path syntax in owner and delivery code."
  @spec legacy_path_violations([String.t()], String.t()) :: [violation()]
  def legacy_path_violations(paths, root \\ File.cwd!()) do
    scan(paths, root, &legacy_violation/1)
  end

  @doc "Returns functions that receive the raw Jidoka owner-ingress message."
  @spec jidoka_ingresses([String.t()], String.t()) :: [map()]
  def jidoka_ingresses(paths, root \\ File.cwd!()) do
    Enum.flat_map(paths, fn path ->
      case quoted(path, root) do
        {:ok, ast} -> ingress_functions(ast, path)
        {:error, _reason} -> []
      end
    end)
  end

  defp scan(paths, root, classifier) do
    Enum.flat_map(paths, fn path ->
      case quoted(path, root) do
        {:ok, ast} -> ast_violations(ast, path, classifier)
        {:error, reason} -> [%{path: path, line: 0, kind: :invalid_syntax, subject: reason}]
      end
    end)
  end

  defp quoted(path, root) do
    root
    |> Path.join(path)
    |> File.read!()
    |> Code.string_to_quoted(columns: true)
  end

  defp ast_violations(ast, path, classifier) do
    {_ast, violations} =
      Macro.prewalk(ast, [], fn node, violations ->
        case classifier.(node) do
          nil -> {node, violations}
          violation -> {node, [Map.put(violation, :path, path) | violations]}
        end
      end)

    violations
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp client_violation(node) do
    module_violation(node) || raw_tag_violation(node) || legacy_violation(node)
  end

  defp module_violation({:__aliases__, meta, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      module = Enum.map_join(parts, ".", &Atom.to_string/1)

      if Enum.any?(@forbidden_module_suffixes, &module_suffix?(module, &1)) do
        violation(meta, :forbidden_module, module)
      end
    end
  end

  defp module_violation(_node), do: nil

  defp module_suffix?(module, suffix), do: module == suffix or String.ends_with?(module, "." <> suffix)

  defp raw_tag_violation({:{}, meta, [tag | _rest]}) when tag in @raw_client_tags,
    do: violation(meta, :raw_message, tag)

  defp raw_tag_violation({tag, _value}) when tag in @raw_client_tags,
    do: violation([], :raw_message, tag)

  defp raw_tag_violation(_node), do: nil

  defp legacy_violation({:mode, :legacy}), do: violation([], :legacy_option, {:mode, :legacy})
  defp legacy_violation({:return_attachment, _value}), do: violation([], :legacy_option, :return_attachment)

  defp legacy_violation({name, meta, args})
       when name in @legacy_functions and is_list(meta) and is_list(args),
       do: violation(meta, :legacy_function, name)

  defp legacy_violation({{:., _dot_meta, [_module, name]}, meta, args})
       when name in @legacy_functions and is_list(meta) and is_list(args),
       do: violation(meta, :legacy_function, name)

  defp legacy_violation({:def, meta, [head | _body]}) do
    case call_signature(head) do
      {:ack, 4} -> violation(meta, :legacy_facade, {:ack, 4})
      {:recover, 2} -> violation(meta, :legacy_facade, {:recover, 2})
      _signature -> nil
    end
  end

  defp legacy_violation(node), do: raw_tag_violation(node)

  defp call_signature({:when, _meta, [head | _guards]}), do: call_signature(head)
  defp call_signature({name, _meta, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp call_signature(_head), do: nil

  defp ingress_functions(ast, path) do
    {_ast, ingresses} =
      Macro.prewalk(ast, [], fn
        {:def, meta, [head | _body]} = node, ingresses ->
          case call_head(head) do
            {:handle_info, _call_meta, args} when is_list(args) ->
              if Enum.any?(args, &contains_tag?(&1, :jidoka_turn_event)) do
                ingress = %{path: path, line: line(meta), function: {:handle_info, length(args)}}
                {node, [ingress | ingresses]}
              else
                {node, ingresses}
              end

            _head ->
              {node, ingresses}
          end

        node, ingresses ->
          {node, ingresses}
      end)

    ingresses |> Enum.reverse() |> Enum.uniq()
  end

  defp call_head({:when, _meta, [head | _guards]}), do: call_head(head)
  defp call_head(head), do: head

  defp contains_tag?(ast, tag) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:{}, _meta, [^tag | _rest]} = node, _found? -> {node, true}
        {^tag, _value} = node, _found? -> {node, true}
        node, found? -> {node, found?}
      end)

    found?
  end

  defp violation(meta, kind, subject),
    do: %{line: line(meta), kind: kind, subject: subject}

  defp line(meta) when is_list(meta), do: Keyword.get(meta, :line, 0)
  defp line(_meta), do: 0
end
