defmodule Jido.Cli.Release.AuditTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Release.Audit

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
    assert_raise ArgumentError, ~r/unknown release-readiness checks/, fn ->
      Audit.run!(checks: ["not-a-check"])
    end
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
