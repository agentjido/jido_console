defmodule Jido.Console.Coding.Network do
  @moduledoc """
  Versioned network policy for restricted coding work.

  Undeclared loopback and external destinations are denied before a connection
  can start. Offline mode denies every destination. Evidence records the
  policy version and destination class only.
  """

  import Bitwise

  @policy_id "jido.network.v1"
  @policy_version "1"
  @file_suffixes ~w(ex exs erl hrl md txt json yaml yml lock html htm css js ts tsx rs go py rb sh bash zsh toml xml csv log pid so dylib beam hex)

  @type class :: :none | :loopback | :external
  @type outcome :: :allow | :deny
  @type destination :: %{host: String.t(), port: integer() | nil, class: class()}
  @type allowlist_entry :: %{
          host: String.t() | nil,
          class: :loopback | :external | nil,
          port: :any | 1..65_535
        }
  @type policy :: %{
          id: String.t(),
          version: String.t(),
          mode: :restricted | :offline,
          allowlist: [allowlist_entry()]
        }
  @type decision :: %{
          outcome: outcome(),
          class: class(),
          reason: String.t(),
          policy: policy()
        }

  @doc "Returns the versioned restricted network policy."
  @spec policy(keyword()) :: {:ok, policy()} | {:error, term()}
  def policy(opts \\ []) do
    mode = if Keyword.get(opts, :offline, false), do: :offline, else: :restricted

    with {:ok, allowlist} <- normalize_allowlist(Keyword.get(opts, :network_allowlist, [])) do
      {:ok,
       %{
         id: @policy_id,
         version: @policy_version,
         mode: mode,
         allowlist: allowlist
       }}
    end
  end

  @doc "Returns an allow or deny decision for one destination string."
  @spec check(String.t(), [map()], keyword()) :: {:ok, decision()} | {:error, term()}
  def check(destination, allowlist, opts \\ []) when is_binary(destination) and is_list(allowlist) do
    admit(%{"args" => [destination]}, Keyword.put(opts, :network_allowlist, allowlist))
  end

  @doc "Admits a command request only when every destination is declared."
  @spec admit(map(), keyword()) :: {:ok, decision()} | {:error, term()}
  def admit(request, opts \\ []) when is_map(request) do
    with {:ok, policy} <- policy(opts) do
      decide(destinations(List.wrap(Map.get(request, "args"))), policy)
    end
  end

  @doc "Projects a redacted evidence record for one decision."
  @spec evidence(decision()) :: map()
  def evidence(decision) do
    %{
      "policy_id" => decision.policy.id,
      "policy_version" => decision.policy.version,
      "mode" => Atom.to_string(decision.policy.mode),
      "class" => Atom.to_string(decision.class),
      "outcome" => Atom.to_string(decision.outcome),
      "reason" => decision.reason,
      "allowlist_entries" => length(decision.policy.allowlist)
    }
  end

  defp decide([], policy) do
    {:ok, decision(:allow, :none, policy, "no network destination")}
  end

  defp decide(dests, %{mode: :offline} = policy) do
    denied(class_of(dests), policy, "offline mode denies network destinations")
  end

  defp decide(dests, policy) do
    case Enum.reject(dests, &allowlisted?(&1, policy.allowlist)) do
      [] ->
        {:ok, decision(:allow, class_of(dests), policy, "destination is on the allowlist")}

      [first | _rest] ->
        denied(first.class, policy, "undeclared #{first.class} access")
    end
  end

  defp denied(class, policy, reason) do
    {:error, {:network_denied, decision(:deny, class, policy, reason)}}
  end

  defp destinations(args) do
    args
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&tokens/1)
    |> Enum.flat_map(&destination/1)
    |> Enum.uniq_by(&{&1.host, &1.port, &1.class})
  end

  defp tokens(arg) do
    arg
    |> String.split(~r/[\s,]/, trim: true)
    |> Enum.reject(&flag?/1)
  end

  defp destination(token) do
    cond do
      uri?(token) -> uri_destination(token)
      host_port = host_port(token) -> [host_port]
      host = host_token(token) -> [host]
      true -> []
    end
  end

  defp uri?(token), do: String.contains?(token, "://")

  defp uri_destination(token) do
    case URI.parse(token) do
      %URI{host: host} = uri when is_binary(host) and host != "" ->
        [%{host: normalize_host(host), port: uri.port, class: classify_host(host)}]

      _other ->
        []
    end
  end

  defp host_port("[" <> rest) do
    case String.split(rest, "]:", parts: 2) do
      [host, port] -> host_port_pair(host, port)
      _other -> nil
    end
  end

  defp host_port(token) do
    case String.split(token, ":", parts: 2) do
      [host, port] -> host_port_pair(host, port)
      _other -> nil
    end
  end

  defp host_port_pair(host, port) do
    parsed_host = host_token(host)
    parsed_port = parse_port(port)

    if parsed_host && parsed_port do
      %{parsed_host | port: parsed_port}
    end
  end

  defp host_token(token) do
    cond do
      ipv4?(token) -> %{host: token, port: nil, class: classify_host(token)}
      ipv6?(token) -> %{host: normalize_host(token), port: nil, class: classify_host(token)}
      hostname?(token) -> %{host: normalize_host(token), port: nil, class: classify_host(token)}
      true -> abbreviated_loopback_host(token)
    end
  end

  defp abbreviated_loopback_host(token) do
    case abbreviated_loopback(token) do
      {:ok, expanded} -> %{host: expanded, port: nil, class: :loopback}
      :error -> nil
    end
  end

  defp ipv4?(token) do
    match?({:ok, _address}, :inet.parse_ipv4strict_address(String.to_charlist(token)))
  end

  defp ipv6?(token) do
    candidate = token |> String.trim_leading("[") |> String.trim_trailing("]")

    String.contains?(candidate, ":") and
      match?({:ok, _address}, :inet.parse_ipv6_address(String.to_charlist(candidate)))
  end

  defp hostname?(token) do
    normalized = String.downcase(token)

    normalized in ["localhost", "localhost.localdomain"] or dns_name?(normalized)
  end

  defp dns_name?(token) do
    labels = String.split(token, ".")

    match?([_head, _tail | _rest], labels) and
      Enum.all?(labels, &dns_label?/1) and
      tld?(List.last(labels))
  end

  defp dns_label?(label) do
    label != "" and String.match?(label, ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/)
  end

  defp tld?(label) do
    String.match?(label, ~r/\A[a-z]{2,24}\z/) and label not in @file_suffixes
  end

  defp classify_host(host) do
    if loopback?(normalize_host(host)), do: :loopback, else: :external
  end

  defp loopback?(host) do
    host in ["localhost", "localhost.localdomain", "::1", "0:0:0:0:0:0:0:1"] or
      ipv4_loopback?(host)
  end

  defp ipv4_loopback?(host) do
    case :inet.parse_ipv4strict_address(String.to_charlist(host)) do
      {:ok, {127, _b, _c, _d}} -> true
      _other -> false
    end
  end

  defp abbreviated_loopback(token) do
    parts = String.split(token, ".")

    if length(parts) in 2..3 do
      case expand_ipv4(parts) do
        {:ok, address} -> if(ipv4_loopback?(address), do: {:ok, address}, else: :error)
        :error -> :error
      end
    else
      :error
    end
  end

  defp expand_ipv4([a, b]) do
    with {:ok, a} <- parse_u8(a), {:ok, b} <- parse_u24(b) do
      {:ok, Enum.join([a, b >>> 16, b >>> 8 &&& 255, b &&& 255], ".")}
    end
  end

  defp expand_ipv4([a, b, c]) do
    with {:ok, a} <- parse_u8(a), {:ok, b} <- parse_u8(b), {:ok, c} <- parse_u16(c) do
      {:ok, Enum.join([a, b, c >>> 8, c &&& 255], ".")}
    end
  end

  defp expand_ipv4(_parts), do: :error

  defp parse_u8(value), do: parse_bounded_int(value, 255)
  defp parse_u16(value), do: parse_bounded_int(value, 65_535)
  defp parse_u24(value), do: parse_bounded_int(value, 16_777_215)

  defp parse_bounded_int(value, max) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 and int <= max -> {:ok, int}
      _other -> :error
    end
  end

  defp allowlisted?(destination, allowlist) do
    Enum.any?(allowlist, &matches_allowlist?(destination, &1))
  end

  defp matches_allowlist?(destination, allowed) do
    class_ok? = allowed.class in [nil, destination.class]
    host_ok? = allowed.host in [nil, destination.host]
    port_ok? = allowed.port == :any or destination.port == allowed.port
    class_ok? and host_ok? and port_ok?
  end

  defp normalize_allowlist(entries) when is_list(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, normalized} ->
      case normalize_allowlist_entry(entry) do
        {:ok, entry} -> {:cont, {:ok, [entry | normalized]}}
        {:error, reason} -> {:halt, {:error, {:invalid_network_allowlist, index, reason}}}
      end
    end)
    |> then(fn
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end)
  end

  defp normalize_allowlist(_entries), do: {:error, {:invalid_network_allowlist, :not_a_list}}

  defp normalize_allowlist_entry(entry) when is_map(entry) do
    with {:ok, selector} <- normalize_selector(entry),
         {:ok, port} <- normalize_allowlist_port(entry) do
      {:ok, Map.put(selector, :port, port)}
    end
  end

  defp normalize_allowlist_entry(_entry), do: {:error, :entry_must_be_a_map}

  defp normalize_selector(entry) do
    case {fetch_entry(entry, :host), fetch_entry(entry, :class)} do
      {{:ok, host}, :missing} -> normalize_host_selector(host)
      {:missing, {:ok, class}} -> normalize_class_selector(class)
      {:missing, :missing} -> {:error, :selector_required}
      _invalid -> {:error, :one_selector_required}
    end
  end

  defp normalize_host_selector(host) when is_binary(host) do
    case host_token(host) do
      %{host: normalized} -> {:ok, %{host: normalized, class: nil}}
      nil -> {:error, :invalid_host}
    end
  end

  defp normalize_host_selector(_host), do: {:error, :invalid_host}

  defp normalize_class_selector(class) do
    case normalize_class(class) do
      class when class in [:loopback, :external] -> {:ok, %{host: nil, class: class}}
      _invalid -> {:error, :invalid_class}
    end
  end

  defp normalize_allowlist_port(entry) do
    case fetch_entry(entry, :port) do
      {:ok, :any} -> {:ok, :any}
      {:ok, port} when is_integer(port) and port in 1..65_535 -> {:ok, port}
      {:ok, port} when is_binary(port) -> parse_allowlist_port(port)
      :missing -> {:error, :port_required}
      _invalid -> {:error, :invalid_port}
    end
  end

  defp parse_allowlist_port(value) do
    case Integer.parse(value) do
      {port, ""} when port in 1..65_535 -> {:ok, port}
      _invalid -> {:error, :invalid_port}
    end
  end

  defp fetch_entry(entry, key) do
    case {Map.fetch(entry, key), Map.fetch(entry, Atom.to_string(key))} do
      {:error, :error} -> :missing
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      {{:ok, _atom_value}, {:ok, _string_value}} -> :duplicate
    end
  end

  defp normalize_class(class) when class in [:loopback, :external, "loopback", "external"] do
    if is_atom(class), do: class, else: String.to_existing_atom(class)
  end

  defp normalize_class(_class), do: nil

  defp normalize_host(host) do
    host
    |> String.trim()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.downcase()
  end

  defp parse_port(value) do
    case Integer.parse(value) do
      {port, ""} when port > 0 and port < 65_536 -> port
      _other -> nil
    end
  end

  defp flag?(token), do: String.starts_with?(token, "-")

  defp class_of(dests) do
    if Enum.any?(dests, &(&1.class == :external)), do: :external, else: :loopback
  end

  defp decision(outcome, class, policy, reason) do
    %{outcome: outcome, class: class, reason: reason, policy: policy}
  end
end
