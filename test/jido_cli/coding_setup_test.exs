defmodule Jido.Cli.CodingSetupTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.CodingSetup
  alias Jidoka.Agent.Spec.Operation

  setup do
    root = Path.join(System.tmp_dir!(), "jido-coding-setup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib/nested"))
    File.write!(Path.join(root, "AGENTS.md"), "root rules")
    File.write!(Path.join(root, "lib/AGENTS.md"), "lib rules")
    File.write!(Path.join(root, "lib/value.ex"), "defmodule Value do\nend\n")
    File.write!(Path.join(root, ".env"), "TOKEN=secret")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "enables the built-in pack and named profile without module names", %{root: root} do
    assert {:ok, setup} = CodingSetup.prepare(Jido.Cli.DefaultAgent, project_root: root)

    assert setup.pack_id == "jido.coding_pack"
    assert setup.profile_id == "coding.default"
    assert setup.spec.id == "jido"
    assert Enum.any?(setup.spec.extensions, &(&1.id == "jido.coding_pack"))
    assert Map.has_key?(setup.extension_setup.registry, "jido.coding_pack")
    assert Enum.map(setup.instructions, & &1["path"]) == ["AGENTS.md"]
    refute inspect(setup.context) =~ root
  end

  test "can disable the full pack or replace it by a trusted ID", %{root: root} do
    assert {:ok, disabled} =
             CodingSetup.prepare(Jido.Cli.DefaultAgent, project_root: root, coding_pack: :disabled)

    assert disabled.pack_id == nil
    assert disabled.extension_setup.projection["status"] == "disabled"

    record = record(root, "acme.coding_pack")
    resolver = fn "acme.coding_pack", _context -> {:ok, fn _, _, _ -> {:error, :fixture} end} end

    assert {:ok, replacement} =
             CodingSetup.prepare(Jido.Cli.DefaultAgent,
               project_root: root,
               coding_pack: "acme.coding_pack",
               extension_record_files: [record],
               built_in_extension_resolver: resolver
             )

    assert replacement.pack_id == "acme.coding_pack"
    assert Map.has_key?(replacement.extension_setup.registry, "acme.coding_pack")
  end

  test "can disable or replace each default tool through trusted host options", %{root: root} do
    changed = %{
      operation: Operation.new!(name: "coding.read", idempotency: :pure),
      handler: fn _, _ -> {:ok, :replacement} end
    }

    assert {:ok, setup} =
             CodingSetup.prepare(Jido.Cli.DefaultAgent,
               project_root: root,
               coding_disable_tools: ["coding.search"],
               coding_replace_tools: %{"coding.read" => changed}
             )

    entry = setup.extension_setup.registry["jido.coding_pack"]
    {:ok, session} = Jidoka.Session.Data.start(setup.spec, session_id: "coding-setup")
    request = Enum.find(setup.spec.extensions, &(&1.id == "jido.coding_pack"))
    assert {:ok, host} = Jidoka.Extension.Host.open(session, [request], %{"jido.coding_pack" => entry}, :interactive)

    assert [[%Operation{name: "coding.read"}]] =
             Enum.map(Jidoka.Extension.Host.operation_sources(host), & &1.operations)

    Jidoka.Extension.Host.close(host)
  end

  test "loads nested instructions in order when the working scope is selected", %{root: root} do
    assert {:ok, setup} = CodingSetup.prepare(Jido.Cli.DefaultAgent, project_root: root)

    assert {:ok, instructions} = Jidoka.CodingPack.Instructions.discover(setup.workspace, "lib/nested")
    assert Enum.map(instructions, & &1["path"]) == ["AGENTS.md", "lib/AGENTS.md"]
  end

  test "rejects raw module names, malformed config, and unknown profiles", %{root: root} do
    assert {:error, :coding_module_name_forbidden} =
             CodingSetup.prepare(Jido.Cli.DefaultAgent, project_root: root, coding_pack: "Elixir.Raw.Module")

    assert {:error, {:invalid_coding_pack, 42}} =
             CodingSetup.prepare(Jido.Cli.DefaultAgent, project_root: root, coding_pack: 42)

    resolver = fn _id -> {:error, :missing} end

    assert {:error, {:unknown_runtime_profile, "missing", :missing}} =
             CodingSetup.prepare(Jido.Cli.DefaultAgent,
               project_root: root,
               coding_profile: "missing",
               coding_profile_resolver: resolver
             )
  end

  test "resolves exact and unique file mentions and keeps escaped literals", %{root: root} do
    assert {:ok, setup} = CodingSetup.prepare(Jido.Cli.DefaultAgent, project_root: root)

    assert {:ok, "Review lib/value.ex and @literal", context} =
             CodingSetup.prepare_prompt(setup, "Review @lib/value.ex and \\@literal")

    assert [%{"path" => "lib/value.ex", "content" => content}] = context["coding"]["files"]
    assert content =~ "defmodule Value"

    assert {:ok, "Review value.ex", unique_context} = CodingSetup.prepare_prompt(setup, "Review @value.ex")
    assert [%{"path" => "lib/value.ex"}] = unique_context["coding"]["files"]
  end

  test "mention errors do not return unsafe context", %{root: root} do
    File.write!(Path.join(root, "lib/nested/value.ex"), "duplicate")
    File.write!(Path.join(root, "binary"), <<0, 1>>)
    File.write!(Path.join(root, "large"), String.duplicate("x", 1_048_577))
    assert {:ok, setup} = CodingSetup.prepare(Jido.Cli.DefaultAgent, project_root: root)

    cases = [
      {"@missing.ex", :coding_file_mention_missing},
      {"@value.ex", :coding_file_mention_ambiguous},
      {"@.env", :coding_path_ignored},
      {"@binary", :coding_file_binary},
      {"@large", :coding_file_too_large},
      {"@../outside", :workspace_path_rejected}
    ]

    for {prompt, code} <- cases do
      assert {:error, {:file_mention_failed, _mention, %Jidoka.CodingPack.Error{code: ^code}}} =
               CodingSetup.prepare_prompt(setup, prompt)
    end
  end

  defp record(root, id) do
    path = Path.join(root, "extensions.json")

    document = %{
      "version" => 1,
      "extensions" => [
        %{
          "id" => id,
          "source" => "built_in",
          "source_ref" => "builtin:replacement",
          "release" => "1",
          "sha256" => "sha256:" <> String.duplicate("a", 64),
          "permissions" => [],
          "capabilities" => [],
          "modes" => ["interactive"],
          "scope" => "user"
        }
      ]
    }

    File.write!(path, Jason.encode!(document))
    path
  end
end
