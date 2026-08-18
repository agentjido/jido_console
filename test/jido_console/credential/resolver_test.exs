defmodule Jido.Console.Credential.ResolverTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Credential.Resolver

  @canary "RESOLVER_CANARY_DO_NOT_ESCAPE"

  defmodule KeychainAdapter do
    @behaviour Jido.Console.Credential.Keychain

    @impl true
    def read(lookup, opts) do
      send(opts[:test_pid], {:module_keychain_read, lookup})
      opts[:keychain_result]
    end
  end

  test "requires a final boundary and blocks a materialized value in the result" do
    reference = environment_reference()

    assert {:error, :credential_final_boundary_required} =
             Resolver.materialize(reference, fn _value -> :ok end, host_env: %{"OPENAI_API_KEY" => @canary})

    assert {:error, {:sensitive_result_blocked, %{"redacted" => true}}} =
             Resolver.materialize(reference, fn value -> %{authorization: "Bearer #{value}"} end,
               boundary: :provider,
               host_env: %{"OPENAI_API_KEY" => @canary}
             )
  end

  test "reads only a named value from a private regular dotenv file" do
    root = Path.join(System.tmp_dir!(), "jido-dotenv-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "credentials.env")
    File.write!(path, "OTHER=value\nOPENAI_API_KEY=#{@canary}\n")
    File.chmod!(path, 0o600)
    on_exit(fn -> File.rm_rf(root) end)

    reference = dotenv_reference()
    test_pid = self()

    assert {:ok, :used} =
             Resolver.materialize(
               reference,
               fn value ->
                 send(test_pid, {:dotenv, value})
                 :used
               end,
               boundary: :tool,
               dotenv_paths: %{"dotenv-main" => path}
             )

    assert_receive {:dotenv, @canary}

    File.chmod!(path, 0o644)

    assert {:error, {:credential_source_denied, _redacted}} =
             Resolver.materialize(reference, fn _value -> :not_called end,
               boundary: :tool,
               dotenv_paths: %{"dotenv-main" => path}
             )
  end

  test "rejects dotenv links, traversal, interpolation, shell text, and missing variables" do
    root = Path.join(System.tmp_dir!(), "jido-dotenv-denial-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "credentials.env")
    link = Path.join(root, "linked.env")
    File.write!(path, "OPENAI_API_KEY=${OTHER_TOKEN}\n")
    File.chmod!(path, 0o600)
    File.ln_s!(path, link)
    on_exit(fn -> File.rm_rf(root) end)

    reference = dotenv_reference()

    for candidate <- [link, Path.join(root, "nested/../credentials.env")] do
      assert {:error, {:credential_source_denied, _redacted}} =
               Resolver.materialize(reference, fn _value -> :not_called end,
                 boundary: :provider,
                 dotenv_paths: %{"dotenv-main" => candidate}
               )
    end

    assert {:error, {:credential_source_denied, _redacted}} =
             Resolver.materialize(reference, fn _value -> :not_called end,
               boundary: :provider,
               dotenv_paths: %{"dotenv-main" => path}
             )

    File.write!(path, "OTHER=value\n")
    File.chmod!(path, 0o600)

    assert {:error, {:credential_source_missing, _redacted}} =
             Resolver.materialize(reference, fn _value -> :not_called end,
               boundary: :provider,
               dotenv_paths: %{"dotenv-main" => path}
             )
  end

  test "uses an injected read-only keychain adapter only on a qualified platform" do
    reference = keychain_reference()
    test_pid = self()

    adapter = fn lookup, _opts ->
      send(test_pid, {:keychain_read, lookup})
      {:ok, @canary}
    end

    assert {:error, {:credential_source_unavailable, _redacted}} =
             Resolver.materialize(reference, fn _value -> :not_called end,
               boundary: :provider,
               platform: "linux",
               keychain_adapter: adapter
             )

    refute_receive {:keychain_read, _lookup}

    assert {:ok, :used} =
             Resolver.materialize(
               reference,
               fn value ->
                 send(test_pid, {:keychain_value, value})
                 :used
               end,
               boundary: :provider,
               platform: "darwin",
               keychain_adapter: adapter
             )

    assert_receive {:keychain_read, %{"item_identity" => "keychain-main"}}
    assert_receive {:keychain_value, @canary}
  end

  test "normalizes environment and callback failures without exposing values" do
    reference = environment_reference()

    assert {:error, :invalid_credential_materialization} = Resolver.materialize(:invalid, :invalid, [])

    for result <- [:error, :missing, {:error, :enoent}, {:error, :missing}] do
      assert {:error, {:credential_source_missing, _redacted}} =
               Resolver.materialize(reference, fn _value -> :not_called end,
                 boundary: :provider,
                 env_fetch: fn _name -> result end
               )
    end

    for result <- [{:error, :eacces}, {:error, :eperm}, {:error, :denied}] do
      assert {:error, {:credential_source_denied, _redacted}} =
               Resolver.materialize(reference, fn _value -> :not_called end,
                 boundary: :provider,
                 env_fetch: fn _name -> result end
               )
    end

    for result <- [{:ok, ""}, {:ok, 42}, {:error, :timeout}, :unexpected] do
      assert {:error, {:credential_source_unavailable, _redacted}} =
               Resolver.materialize(reference, fn _value -> :not_called end,
                 boundary: :provider,
                 env_fetch: fn _name -> result end
               )
    end

    assert {:error, {:credential_source_missing, _redacted}} =
             Resolver.materialize(reference, fn _value -> :not_called end,
               boundary: :provider,
               host_env: :invalid
             )

    assert {:error, {:credential_source_unavailable, _redacted}} =
             Resolver.materialize(reference, fn _value -> :not_called end,
               boundary: :provider,
               env_fetch: fn _name -> raise "environment unavailable" end
             )

    assert {:error, {:credential_boundary_failed, RuntimeError}} =
             Resolver.materialize(reference, fn _value -> raise "provider failed" end,
               boundary: :provider,
               host_env: %{"OPENAI_API_KEY" => @canary}
             )

    assert {:error, {:credential_boundary_failed, :throw}} =
             Resolver.materialize(reference, fn _value -> throw(:provider_failed) end,
               boundary: :tool,
               host_env: %{"OPENAI_API_KEY" => @canary}
             )
  end

  test "enforces strict dotenv identity, ownership, size, and syntax" do
    root = Path.join(System.tmp_dir!(), "jido-dotenv-strict-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "credentials.env")
    on_exit(fn -> File.rm_rf(root) end)
    reference = dotenv_reference()
    test_pid = self()

    File.write!(path, "# private credentials\r\n\r\nOPENAI_API_KEY='#{@canary}'\r\n")
    File.chmod!(path, 0o600)

    assert {:ok, :used} =
             Resolver.materialize(
               reference,
               fn value ->
                 send(test_pid, {:quoted, value})
                 :used
               end,
               boundary: :provider,
               dotenv_paths: %{"dotenv-main" => path}
             )

    assert_receive {:quoted, @canary}

    denied_candidates = [
      "OPENAI_API_KEY=first\nOPENAI_API_KEY=second\n",
      "OPENAI_API_KEY='unterminated\n",
      "INVALID NAME=value\n",
      "OPENAI_API_KEY=$(command)\n"
    ]

    Enum.each(denied_candidates, fn contents ->
      File.write!(path, contents)
      File.chmod!(path, 0o600)

      assert {:error, {:credential_source_denied, _redacted}} =
               Resolver.materialize(reference, fn _value -> :not_called end,
                 boundary: :provider,
                 dotenv_paths: %{"dotenv-main" => path}
               )
    end)

    File.write!(path, "OPENAI_API_KEY=#{@canary}\n")
    File.chmod!(path, 0o600)

    assert {:error, {:credential_source_denied, _redacted}} =
             Resolver.materialize(reference, fn _value -> :not_called end,
               boundary: :provider,
               dotenv_paths: %{"dotenv-main" => path},
               owner_uid: -1
             )

    File.write!(path, :binary.copy("A", 64 * 1_024 + 1))
    File.chmod!(path, 0o600)

    assert {:error, {:credential_source_denied, _redacted}} =
             Resolver.materialize(reference, fn _value -> :not_called end,
               boundary: :provider,
               dotenv_paths: %{"dotenv-main" => path}
             )

    assert {:error, {:credential_source_missing, _redacted}} =
             Resolver.materialize(reference, fn _value -> :not_called end,
               boundary: :provider,
               dotenv_paths: %{}
             )

    assert {:error, {:credential_source_denied, _redacted}} =
             Resolver.materialize(reference, fn _value -> :not_called end,
               boundary: :provider,
               dotenv_paths: :invalid
             )
  end

  test "normalizes read-only keychain adapter results" do
    reference = keychain_reference()

    assert {:ok, :used} =
             Resolver.materialize(reference, fn _value -> :used end,
               boundary: :provider,
               platform: "darwin",
               keychain_adapter: KeychainAdapter,
               keychain_result: {:ok, @canary},
               test_pid: self()
             )

    assert_receive {:module_keychain_read, %{"item_identity" => "keychain-main"}}

    assert {:error, {:credential_source_missing, _redacted}} =
             Resolver.materialize(reference, fn _value -> :not_called end,
               boundary: :provider,
               platform: "darwin",
               keychain_adapter: KeychainAdapter,
               keychain_result: :missing,
               test_pid: self()
             )

    assert {:error, {:credential_source_unavailable, _redacted}} =
             Resolver.materialize(reference, fn _value -> :not_called end,
               boundary: :provider,
               platform: "darwin"
             )

    assert {:error, {:credential_source_unavailable, _redacted}} =
             Resolver.materialize(reference, fn _value -> :not_called end,
               boundary: :provider,
               platform: "darwin",
               keychain_adapter: String
             )

    assert {:error, {:credential_source_unavailable, _redacted}} =
             Resolver.materialize(%{"kind" => "unsupported", "reference_id" => "other"}, fn _ -> :unused end,
               boundary: :provider
             )
  end

  test "contains values and normalizes portable source failures" do
    environment = environment_reference()

    assert {:error, {:sensitive_result_blocked, %{"redacted" => true}}} =
             Resolver.materialize(environment, fn value -> [:result, value] end,
               boundary: :provider,
               host_env: %{"OPENAI_API_KEY" => @canary}
             )

    assert {:ok, %{status: [:used]}} =
             Resolver.materialize(environment, fn _value -> %{status: [:used]} end,
               boundary: :provider,
               host_env: %{"OPENAI_API_KEY" => @canary}
             )

    assert {:error, {:credential_source_unavailable, _redacted}} =
             Resolver.materialize(environment, fn _value -> :not_called end,
               boundary: :provider,
               env_fetch: fn _name -> throw(:environment_failed) end
             )

    missing_path =
      Path.join(System.tmp_dir!(), "missing-dotenv-#{System.unique_integer([:positive])}.env")

    assert {:error, {:credential_source_missing, _redacted}} =
             Resolver.materialize(dotenv_reference(), fn _value -> :not_called end,
               boundary: :provider,
               dotenv_paths: %{"dotenv-main" => missing_path}
             )

    assert {:error, {:credential_source_denied, _redacted}} =
             Resolver.materialize(dotenv_reference(), fn _value -> :not_called end,
               boundary: :provider,
               dotenv_paths: %{"dotenv-main" => System.tmp_dir!()}
             )

    assert {:error, {:credential_source_denied, _redacted}} =
             Resolver.materialize(dotenv_reference(), fn _value -> :not_called end,
               boundary: :provider,
               dotenv_paths: %{"dotenv-main" => 42}
             )

    assert {:error, {:credential_source_unavailable, _redacted}} =
             Resolver.materialize(keychain_reference(), fn _value -> :not_called end,
               boundary: :provider,
               platform: "darwin",
               keychain_adapter: fn _lookup, _opts -> raise "keychain failed" end
             )
  end

  defp environment_reference do
    %{
      "reference_id" => "host-openai",
      "kind" => "environment",
      "source_identity" => "host-primary",
      "lookup" => %{"name" => "OPENAI_API_KEY"}
    }
  end

  defp dotenv_reference do
    %{
      "reference_id" => "dotenv-openai",
      "kind" => "private_dotenv",
      "source_identity" => "host-primary",
      "lookup" => %{"file_identity" => "dotenv-main", "variable" => "OPENAI_API_KEY"}
    }
  end

  defp keychain_reference do
    %{
      "reference_id" => "keychain-openai",
      "kind" => "keychain_item",
      "source_identity" => "host-primary",
      "lookup" => %{
        "item_identity" => "keychain-main",
        "service" => "jido",
        "account" => "openai"
      }
    }
  end
end
