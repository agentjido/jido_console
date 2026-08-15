defmodule Jido.Console.JidokaCompatibilityTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Release.Identity
  alias Jidoka.ExecutionEnvironment.RestrictedContract
  alias Jidoka.Policy.Decision

  @jidoka_ref "7a346949aeb5c829ee0fad7b6b38eb23839b1384"

  test "the pinned Jidoka source is one immutable Git commit" do
    assert Identity.jidoka_ref() == @jidoka_ref

    {_app, options} =
      Mix.Project.config()
      |> Keyword.fetch!(:deps)
      |> Enum.find(fn {app, _options} -> app == :jidoka end)

    assert options[:github] == "agentjido/jidoka"
    assert options[:ref] == @jidoka_ref
    refute Keyword.has_key?(options, :path)
    refute Keyword.has_key?(options, :branch)
  end

  test "the pinned release exposes the v0.1 restricted compatibility contract" do
    assert :consent_required in Decision.outcomes()
    assert :unsupported in Decision.outcomes()
    assert RestrictedContract.compatibility()["release_target"] == "v0.1"

    digest = Jidoka.ExecutionEnvironment.digest(%{"root" => "console-compat"})

    assert {:ok, contract} =
             RestrictedContract.new(
               profile_id: "coding.restricted",
               roots:
                 Enum.map(RestrictedContract.root_kinds(), fn kind ->
                   %{kind: kind, digest: digest, writable: kind != :toolchain}
                 end),
               environment: %{allowlist: ["PATH"], private_home: true},
               cancellation: %{enabled: true},
               deadline_ms: 30_000,
               cleanup: %{status: :clean, child_processes: 0}
             )

    assert :ok = RestrictedContract.compatible?(contract)
  end
end
