defmodule Jido.Console.Coding.ApprovalTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Coding.Approval

  @effect %{
    operation: "coding.edit",
    path: "lib/value.ex",
    params: %{old_text: "41", new_text: "42", OPENAI_API_KEY: "sk-secretvalue"}
  }

  @context %{
    workspace: "sha256:workspace",
    run_id: "run-1",
    profile_id: "coding.restricted",
    roots: %{"workspace" => "declared", "temporary" => "declared"},
    network_policy: "jido.network.v1",
    process_owner: "coding"
  }

  test "binds a stable identity that includes normalized parameters" do
    assert {:ok, binding} = Approval.bind(@effect, @context)
    assert {:ok, identity} = Approval.identity(@effect, @context)
    assert identity == binding.id
    assert binding.status == :pending
    assert binding.params["old_text"] == "41"
    refute inspect(binding) =~ "sk-secretvalue"
    refute Approval.format(binding) =~ "sk-secretvalue"
  end

  test "rejects another effect, run, workspace, or parameter set" do
    assert {:ok, binding} = Approval.bind(@effect, @context)

    assert {:error, :approval_mismatch} =
             Approval.authorize(binding, %{@effect | path: "lib/other.ex"}, @context)

    assert {:error, :approval_mismatch} =
             Approval.authorize(binding, %{@effect | params: %{old_text: "41", new_text: "43"}}, @context)

    assert {:error, :approval_mismatch} =
             Approval.authorize(binding, @effect, %{@context | run_id: "run-2"})

    assert {:error, :approval_mismatch} =
             Approval.authorize(binding, @effect, %{@context | workspace: "sha256:other"})
  end

  test "rejects replay after the effect has completed or failed" do
    assert {:ok, binding} = Approval.bind(@effect, @context)
    assert {:ok, binding} = Approval.authorize(binding, @effect, @context)
    assert {:ok, completed} = Approval.consume(binding, :completed)
    assert {:error, :approval_replay} = Approval.authorize(completed, @effect, @context)
    assert {:error, :approval_replay} = Approval.consume(completed, :completed)

    assert {:ok, pending} = Approval.bind(@effect, @context)
    assert {:ok, failed} = Approval.consume(pending, :failed)
    assert {:error, :approval_replay} = Approval.authorize(failed, @effect, @context)
  end

  test "invalidates approval when profile, roots, network, or owner change" do
    assert {:ok, binding} = Approval.bind(@effect, @context)

    Enum.each(
      [
        %{profile_id: "coding.trusted-workspace"},
        %{roots: %{"workspace" => "other"}},
        %{network_policy: "jido.network.v2"},
        %{process_owner: "other"}
      ],
      fn change ->
        assert {:error, :approval_mismatch} =
                 Approval.authorize(binding, @effect, Map.merge(@context, change))
      end
    )
  end

  test "redacts sensitive paths and does not leak secrets in denials" do
    secret = %{@effect | path: ".env", params: %{contents: "OPENAI_API_KEY=sk-secretvalue"}}
    assert {:ok, binding} = Approval.bind(secret, @context)
    assert binding.path == ".env"
    assert Approval.display_path(binding.path) == "[redacted]"
    assert Approval.format(binding) =~ "[redacted]"
    refute Approval.format(binding) =~ ".env"
    assert {:error, :approval_mismatch} = Approval.authorize(binding, @effect, @context)
    refute inspect(binding) =~ "sk-secretvalue"
  end
end
