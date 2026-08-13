defmodule Jido.Cli.EnvTest do
  use ExUnit.Case, async: false

  alias Jido.Cli.Env

  setup do
    root = Path.join(System.tmp_dir!(), "jido-env-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    original = Map.new(["OPENAI_API_KEY", "ANTHROPIC_API_KEY"], &{&1, System.get_env(&1)})

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
end
