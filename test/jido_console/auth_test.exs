defmodule Jido.Console.AuthTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Jido.Console.Auth

  @secret "sk-super-secret-credential"

  test "resolves declared sources with host variables taking precedence" do
    root = Path.join(System.tmp_dir!(), "jido-auth-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    env_file = Path.join(root, ".env")
    File.write!(env_file, "OPENAI_API_KEY=#{@secret}\nANTHROPIC_API_KEY=file-anthropic\n")
    File.chmod!(env_file, 0o600)
    on_exit(fn -> File.rm_rf!(root) end)

    host = %{"OPENAI_API_KEY" => "host-openai"}

    assert {:ok, rows} = Auth.status(host_env: host, env_file: env_file)
    openai = Enum.find(rows, &(&1.provider == "openai"))
    anthropic = Enum.find(rows, &(&1.provider == "anthropic"))
    ollama = Enum.find(rows, &(&1.provider == "ollama"))

    assert openai.state == :present
    assert openai.source == :host_env
    assert anthropic.state == :present
    assert anthropic.source == :env_file
    assert ollama.state == :not_required
    refute inspect(rows) =~ @secret
    refute inspect(rows) =~ "host-openai"
    refute inspect(rows) =~ "file-anthropic"
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
end
