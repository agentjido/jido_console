defmodule Jido.Console.Coding.Network do
  @moduledoc """
  Versioned network policy for restricted coding work.

  Undeclared loopback and external destinations are denied before a connection
  can start. Offline mode denies every destination. Evidence records the
  policy version and destination class only.
  """

  @policy_id "jido.network.v1"
  @policy_version "1"

  @type class :: :none | :loopback | :external
  @type outcome :: :allow | :deny
  @type destination :: %{host: String.t(), port: integer() | nil, class: class()}
  @type policy :: %{
          id: String.t(),
          version: String.t(),
          mode: :restricted | :offline,
          allowlist: [map()]
        }
  @type decision :: %{
          outcome: outcome(),
          class: class(),
          reason: String.t(),
          policy: policy()
        }

  @doc "Returns the versioned restricted network policy."
  @spec policy(keyword()) :: policy()
  def policy(opts \\ []) do
    mode = if Keyword.get(opts, :offline, false), do: :offline, else: :restricted

    %{
      id: @policy_id,
      version: @policy_version,
      mode: mode,
      allowlist: normalize_allowlist(Keyword.get(opts, :network_allowlist, []))
    }
  end

  @doc "Returns an allow or deny decision for one destination string."
  @spec check(String.t(), [map()], keyword()) :: {:ok, decision()} | {:error, term()}
  def check(destination, allowlist, opts \\ []) when is_binary(destination) and is_list(allowlist) do
    admit(%{"args" => [destination]}, Keyword.put(opts, :network_allowlist, allowlist))
  end

  @doc "Admits a command request only when every destination is declared."
  @spec admit(map(), keyword()) :: {:ok, decision()} | {:error, {:network_denied, decision()}}
  def admit(request, opts \\ []) when is_map(request) do
    decide(destinations(List.wrap(Map.get(request, "args"))), policy(opts))
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
      %URI{host: host} when is_binary(host) and host != "" ->
        [%{host: normalize_host(host), port: nil, class: classify_host(host)}]

      _other ->
        []
    end
  end

  defp host_port(token) do
    case String.split(token, ":", parts: 2) do
      [host, port] ->
        parsed_host = host_token(host)
        parsed_port = parse_port(port)

        if parsed_host && parsed_port do
          %{parsed_host | port: parsed_port}
        else
          nil
        end

      _other ->
        nil
    end
  end

  defp host_token(token) do
    cond do
      ipv4?(token) -> %{host: token, port: nil, class: classify_host(token)}
      ipv6?(token) -> %{host: normalize_host(token), port: nil, class: classify_host(token)}
      hostname?(token) -> %{host: normalize_host(token), port: nil, class: classify_host(token)}
      true -> nil
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

    String.contains?(normalized, ".") or
      normalized in ["localhost", "localhost.localdomain"]
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

  defp allowlisted?(destination, allowlist) do
    Enum.any?(allowlist, &matches_allowlist?(destination, &1))
  end

  defp matches_allowlist?(destination, allowed) do
    class_ok? = allowed.class in [nil, destination.class]
    host_ok? = allowed.host in [nil, destination.host]
    port_ok? = allowed.port in [nil, destination.port] or destination.port == nil
    class_ok? and host_ok? and port_ok? and (allowed.host != nil or allowed.class != nil)
  end

  defp normalize_allowlist(entries) when is_list(entries) do
    Enum.map(entries, &normalize_allowlist_entry/1)
  end

  defp normalize_allowlist(_entries), do: []

  defp normalize_allowlist_entry(entry) when is_map(entry) do
    host = entry[:host] || entry["host"]
    class = entry[:class] || entry["class"]
    port = entry[:port] || entry["port"]

    %{
      host: if(is_binary(host), do: normalize_host(host), else: nil),
      class: normalize_class(class),
      port: if(is_integer(port), do: port, else: nil)
    }
  end

  defp normalize_allowlist_entry(_entry), do: %{host: nil, class: nil, port: nil}

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
