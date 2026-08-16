defmodule Jido.Console.Release.AuditTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Release.Audit
  alias Jido.Console.Release.Readiness

  test "runs default checks in readiness order" do
    parent = self()
    output = temporary_path()

    Audit.run!(
      source_reader: fn _root -> source() end,
      check_runner: fn name, _opts ->
        send(parent, {:check, name})
        %{"status" => "passed"}
      end,
      temporary_directory: fn -> output end
    )

    observed =
      Enum.map(Readiness.checks(), fn _name ->
        assert_receive {:check, name}
        name
      end)

    assert observed == Readiness.checks()

    refute_received {:check, _name}
  end

  test "removes the default local result" do
    parent = self()
    output = temporary_path()

    result =
      Audit.run!(
        checks: ["support-policy"],
        source_reader: fn _root -> source() end,
        check_runner: fn "support-policy", _opts -> %{"status" => "passed"} end,
        temporary_directory: fn ->
          send(parent, {:temporary_output, output})
          output
        end,
        clock: fn -> ~U[2026-08-15 12:00:00Z] end
      )

    assert_received {:temporary_output, ^output}
    assert result["status"] == "passed"
    assert result["retained"] == false
    assert result["output"] == nil
    refute File.exists?(output)
  end

  test "keeps an explicit local result" do
    output = temporary_path()
    on_exit(fn -> File.rm_rf!(output) end)

    assert %{"retained" => true, "output" => ^output} =
             Audit.run!(
               checks: ["delivery-plan"],
               output: output,
               source_reader: fn _root -> source() end,
               check_runner: fn "delivery-plan", _opts -> %{"status" => "passed"} end
             )

    manifest = output |> Path.join("audit.json") |> File.read!() |> Jason.decode!()
    assert manifest["status"] == "passed"
    assert manifest["source"] == source()
    assert manifest["publication"] == "not_performed"
  end

  test "rejects an unknown check" do
    parent = self()

    assert_raise ArgumentError, ~r/unknown release-readiness checks/, fn ->
      Audit.run!(
        checks: ["not-a-check"],
        source_reader: fn _root -> send(parent, :source_read) end,
        check_runner: fn _name, _opts -> send(parent, :check_started) end
      )
    end

    refute_received :source_read
    refute_received :check_started
  end

  defp source do
    %{
      "commit" => String.duplicate("a", 40),
      "tree" => String.duplicate("b", 40),
      "mix_lock_sha256" => String.duplicate("c", 64),
      "toolchain" => %{"elixir" => "1", "otp" => "1", "mix" => "1"}
    }
  end

  defp temporary_path do
    id = System.unique_integer([:positive, :monotonic])
    Path.join(System.tmp_dir!(), "jido-audit-test-#{id}")
  end
end
