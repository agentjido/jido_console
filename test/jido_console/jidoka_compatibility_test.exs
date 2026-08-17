defmodule Jido.Console.JidokaCompatibilityTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Release.Identity
  alias Jido.Console.Session.Jidoka, as: SessionJidoka
  alias Jidoka.Event
  alias Jidoka.ExecutionEnvironment.RestrictedContract
  alias Jidoka.Policy.Decision

  @jidoka_ref "29246d0a762fe1b17f4250e4f5c98c9f3f6d8419"

  test "production uses the immutable pin and the compatibility gate uses its explicit checkout" do
    assert Identity.jidoka_ref() == @jidoka_ref

    {_app, options} =
      Mix.Project.config()
      |> Keyword.fetch!(:deps)
      |> Enum.find(fn {app, _options} -> app == :jidoka end)

    case System.get_env("JIDO_CONSOLE_JIDOKA_PATH") do
      nil ->
        assert options[:github] == "agentjido/jidoka"
        assert options[:ref] == @jidoka_ref
        refute Keyword.has_key?(options, :path)
        refute Keyword.has_key?(options, :branch)

      checkout ->
        assert Path.expand(options[:path]) == Path.expand(checkout)
        refute Keyword.has_key?(options, :github)
        refute Keyword.has_key?(options, :ref)
        refute Keyword.has_key?(options, :branch)
    end
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

  test "ordered events, handles, and projection use the documented facade" do
    events = [
      Event.build(:turn_started, [], request_id: "compat-1", seq: 0),
      Event.build(:turn_finished, [], request_id: "compat-1", seq: 1)
    ]

    assert :ok = SessionJidoka.validate_events(events)
    assert {:ok, projected} = SessionJidoka.project_events(events)
    assert Enum.map(projected, & &1.request_id) == ["compat-1", "compat-1"]
    assert List.last(projected).terminal?
    assert {:ok, _} = Jason.encode(projected)
  end
end
