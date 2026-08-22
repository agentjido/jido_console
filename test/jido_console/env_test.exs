defmodule Jido.Console.EnvTest do
  use ExUnit.Case, async: false

  alias Jido.Console.{Auth, Env}

  setup do
    root = Path.join(System.tmp_dir!(), "jido-env-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    original = Map.new(Env.provider_keys(), &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "loads known provider keys and keeps the host environment as final authority", %{root: root} do
    path = Path.join(root, ".env")
    File.write!(path, "OPENAI_API_KEY=file-openai\nANTHROPIC_API_KEY=file-anthropic\nOTHER=value\n")
    File.chmod!(path, 0o600)
    System.put_env("OPENAI_API_KEY", "host-openai")
    System.delete_env("ANTHROPIC_API_KEY")

    assert :ok = Env.load_provider_credentials(root)
    assert System.get_env("OPENAI_API_KEY") == "host-openai"
    assert System.get_env("ANTHROPIC_API_KEY") == "file-anthropic"
    assert System.get_env("OTHER") == nil
  end

  test "rejects a credential file that other users can read", %{root: root} do
    path = Path.join(root, ".env")
    File.write!(path, "OPENAI_API_KEY=value\n")
    File.chmod!(path, 0o644)

    assert {:error, {:dotenv_permissions_too_open, ^path}} = Env.load_provider_credentials(root)
  end

  test "loader and status apply the same fail-closed private-file table", %{root: root} do
    path = Path.join(root, ".env")
    target = Path.join(root, "credential-target")
    File.write!(target, "OPENAI_API_KEY=target-secret\n")
    File.chmod!(target, 0o600)

    cases = [
      {:symbolic_link, fn -> File.ln_s!(target, path) end, {:dotenv_not_regular, path, :symlink}},
      {:non_regular, fn -> File.mkdir!(path) end, {:dotenv_not_regular, path, :directory}},
      {:open_permissions, fn -> write_env(path, 0o640) end, {:dotenv_permissions_too_open, path}}
    ]

    Enum.each(cases, fn {_name, setup_file, expected} ->
      File.rm_rf!(path)
      setup_file.()

      assert {:error, ^expected} = Env.load_provider_credentials(root)
      assert {:error, ^expected} = Auth.status(provider: "openai", host_env: %{}, env_file: path)
    end)
  end

  test "loader and status accept the same private regular file", %{root: root} do
    path = Path.join(root, ".env")
    write_env(path, 0o600)
    System.delete_env("OPENAI_API_KEY")

    assert :ok = Env.load_provider_credentials(root)
    assert System.get_env("OPENAI_API_KEY") == "file-secret"

    assert {:ok, [row]} = Auth.status(provider: "openai", host_env: %{}, env_file: path)
    assert row.source == :env_file
    refute inspect(row) =~ "file-secret"
  end

  test "loads the broader provider key contract", %{root: root} do
    path = Path.join(root, ".env")

    contents =
      Env.provider_keys()
      |> Enum.map_join("", fn key -> "#{key}=value-for-#{key}\n" end)

    File.write!(path, contents)
    File.chmod!(path, 0o600)
    Enum.each(Env.provider_keys(), &System.delete_env/1)

    assert :ok = Env.load_provider_credentials(root)

    Enum.each(Env.provider_keys(), fn key ->
      assert System.get_env(key) == "value-for-#{key}"
    end)
  end

  test "treats a missing file as optional and rejects invalid dotenv syntax", %{root: root} do
    assert :ok = Env.load_provider_credentials(root)

    path = Path.join(root, ".env")
    File.write!(path, "NOT VALID DOTENV SYNTAX\n")
    File.chmod!(path, 0o600)

    assert {:error, {:dotenv_load_failed, :invalid_file}} = Env.load_provider_credentials(root)

    assert {:error, {:dotenv_stat_failed, _, :enoent}} =
             Jido.Console.Credentials.read_private_env_file(path <> ".missing")
  end

  defp write_env(path, mode) do
    File.write!(path, "OPENAI_API_KEY=file-secret\n")
    File.chmod!(path, mode)
  end
end
