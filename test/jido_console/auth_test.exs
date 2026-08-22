defmodule Jido.Console.AuthTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Jido.Console.Auth

  @secret "sk-super-secret-credential"

  test "resolves each provider from its declared precedence table" do
    root = Path.join(System.tmp_dir!(), "jido-auth-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    env_file = Path.join(root, ".env")

    File.write!(
      env_file,
      "OPENAI_API_KEY=#{@secret}\nANTHROPIC_API_KEY=file-anthropic\n" <>
        "GEMINI_API_KEY=file-gemini\nGOOGLE_API_KEY=file-google\n"
    )

    File.chmod!(env_file, 0o600)
    on_exit(fn -> File.rm_rf!(root) end)

    cases = [
      {"openai", %{"OPENAI_API_KEY" => "host-openai"}, :host_env, "OPENAI_API_KEY"},
      {"anthropic", %{}, :env_file, "ANTHROPIC_API_KEY"},
      {"google", %{"GOOGLE_API_KEY" => "host-google"}, :env_file, "GEMINI_API_KEY"},
      {"google", %{"GEMINI_API_KEY" => "host-gemini"}, :host_env, "GEMINI_API_KEY"},
      {"ollama", %{"OLLAMA_API_KEY" => "ignored"}, :none, nil}
    ]

    Enum.each(cases, fn {provider, host_env, source, variable} ->
      assert {:ok, [row]} = Auth.status(provider: provider, host_env: host_env, env_file: env_file)
      assert row.source == source
      assert row.variable == variable
      assert row.state == if(provider == "ollama", do: :not_required, else: :present)

      for secret <- [@secret, "host-openai", "file-anthropic", "host-google", "file-gemini"] do
        refute inspect(row) =~ secret
      end
    end)
  end

  test "uses the second Google alternative when Gemini is absent" do
    root = Path.join(System.tmp_dir!(), "jido-auth-google-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    env_file = Path.join(root, ".env")
    File.write!(env_file, "GOOGLE_API_KEY=file-google\n")
    File.chmod!(env_file, 0o600)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, [row]} = Auth.status(provider: "google", host_env: %{}, env_file: env_file)
    assert row.source == :env_file
    assert row.variable == "GOOGLE_API_KEY"
    refute inspect(row) =~ "file-google"
  end

  test "reports missing credentials without values" do
    assert {:ok, [row]} = Auth.status(provider: "openai", host_env: %{})
    assert row.state == :missing
    assert row.reason =~ "OPENAI_API_KEY"
    refute row.reason =~ @secret
  end

  test "rejects credential values in command arguments" do
    assert {:error, :credential_argument_rejected} =
             Auth.reject_credential_args(["--token", @secret])

    output =
      capture_io(:stderr, fn ->
        assert {:error, 64} = Jido.Console.run(["auth", "status", "OPENAI_API_KEY=#{@secret}"])
      end)

    refute output =~ @secret
  end

  test "auth status and doctor commands stay redacted" do
    status = capture_io(fn -> assert :ok = Jido.Console.run(["auth", "status"], host_env: %{}) end)
    assert status =~ "PROVIDER"
    assert status =~ "openai"
    refute status =~ @secret

    doctor = capture_io(fn -> assert :ok = Jido.Console.run(["doctor"], host_env: %{}) end)
    assert doctor =~ "jido doctor"
    assert doctor =~ "jido.models.v0.1"
    refute doctor =~ @secret
  end

  test "all status and doctor projections omit selected values" do
    values = [
      "openai-secret-value",
      "anthropic-secret-value",
      "gemini-secret-value",
      "google-secret-value"
    ]

    host =
      ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY"]
      |> Enum.zip(values)
      |> Map.new()

    assert {:ok, rows} = Auth.status(host_env: host)
    assert {:ok, report} = Auth.doctor(host_env: host)

    diagnostics = inspect(rows) <> Auth.format_status(rows) <> inspect(report) <> Auth.format_doctor(report)

    Enum.each(values, &refute(diagnostics =~ &1))
  end

  test "exposes the credential contract and rejects unknown providers" do
    assert Auth.sources()["openai"] == [%{variable: "OPENAI_API_KEY", required: true}]
    assert {:ok, []} = Auth.sources_for("ollama")
    assert {:error, {:unknown_provider, "missing"}} = Auth.sources_for("missing")
    assert {:error, :invalid_provider} = Auth.status(provider: :openai)
  end
end
