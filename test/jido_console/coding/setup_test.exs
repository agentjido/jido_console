defmodule Jido.Console.Coding.SetupTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Coding.Setup
  alias Jidoka.Agent.Spec.Operation

  setup do
    root = Path.join(System.tmp_dir!(), "jido-coding-setup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib/nested"))
    File.write!(Path.join(root, "AGENTS.md"), "root rules")
    File.write!(Path.join(root, "lib/AGENTS.md"), "lib rules")
    File.write!(Path.join(root, "lib/value.ex"), "defmodule Value do\nend\n")
    File.write!(Path.join(root, "lib/nested/with space.ex"), "defmodule WithSpace do\nend\n")
    File.write!(Path.join(root, ".env"), "TOKEN=secret")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, home: Path.join(root, "home")}
  end

  test "enables the built-in pack and named profile without module names", %{root: root, home: home} do
    setup = prepared(project_root: root, jido_home: home)

    assert setup.pack_id == "jido.coding_pack"
    assert setup.profile_id == "coding.restricted"
    assert setup.context["coding"]["profile"]["id"] == "coding.restricted"
    assert setup.context["coding"]["profile"]["sandbox"] == false
    assert setup.context["coding"]["profile"]["enforcement"] == "pending"
    assert setup.spec.id == "jido"
    assert Enum.any?(setup.spec.extensions, &(&1.id == "jido.coding_pack"))
    assert Map.has_key?(setup.extension_setup.registry, "jido.coding_pack")
    assert Enum.map(setup.instructions, & &1["path"]) == ["AGENTS.md"]
    refute inspect(setup.context) =~ root
  end

  test "tells the model to use path search for a directory listing", %{root: root, home: home} do
    setup = prepared(project_root: root, jido_home: home)

    assert setup.spec.instructions =~
             ~s|coding.search (list paths): {"mode":"path","path":".","pattern":"*"}|

    assert setup.spec.instructions =~
             "Use coding.search with mode `path` to list files or directories."

    assert setup.spec.instructions =~
             "coding.git_status shows changed files only. A clean status does not mean"
  end

  test "can disable the full pack or replace it by a trusted ID", %{root: root} do
    disabled = prepared(project_root: root, coding_pack: :disabled)

    assert disabled.pack_id == nil
    assert disabled.extension_setup.projection["status"] == "disabled"

    record = record(root, "acme.coding_pack")
    resolver = fn "acme.coding_pack", _context -> {:ok, fn _, _, _ -> {:error, :fixture} end} end

    replacement =
      prepared(
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
      operation:
        Operation.new!(
          name: "coding.read",
          idempotency: :pure,
          metadata: %{
            "parameters_schema" => %{
              "type" => "object",
              "properties" => %{},
              "additionalProperties" => false
            }
          }
        ),
      handler: fn _, _ -> {:ok, :replacement} end
    }

    setup =
      prepared(
        project_root: root,
        coding_disable_tools: ["coding.search"],
        coding_replace_tools: %{"coding.read" => changed}
      )

    entry = setup.extension_setup.registry["jido.coding_pack"]
    {:ok, session} = Jidoka.Session.Data.start(setup.spec, session_id: "coding-setup")
    request = Enum.find(setup.spec.extensions, &(&1.id == "jido.coding_pack"))
    assert {:ok, host} = Jidoka.Extension.Host.open(session, [request], %{"jido.coding_pack" => entry}, :interactive)

    operations =
      host
      |> Jidoka.Extension.Host.operation_sources()
      |> Enum.flat_map(& &1.operations)

    names = Enum.map(operations, & &1.name)
    assert "coding.read" in names
    refute "coding.search" in names

    assert %Operation{name: "coding.read", metadata: %{"parameters_schema" => %{"properties" => %{}}}} =
             Enum.find(operations, &(&1.name == "coding.read"))

    Jidoka.Extension.Host.close(host)
  end

  test "loads nested instructions in order when the working scope is selected", %{root: root} do
    setup = prepared(project_root: root)

    assert {:ok, instructions} = Jidoka.CodingPack.Instructions.discover(setup.workspace, "lib/nested")
    assert Enum.map(instructions, & &1["path"]) == ["AGENTS.md", "lib/AGENTS.md"]
  end

  test "rejects raw module names, malformed config, and unknown profiles", %{root: root} do
    assert {:error, :coding_module_name_forbidden} =
             Setup.prepare(Jido.Console.DefaultAgent, project_root: root, coding_pack: "Elixir.Raw.Module")

    assert {:error, {:invalid_coding_pack, 42}} =
             Setup.prepare(Jido.Console.DefaultAgent, project_root: root, coding_pack: 42)

    resolver = fn _id -> {:error, :missing} end

    assert {:error, {:unknown_runtime_profile, "missing", :missing}} =
             Setup.prepare(Jido.Console.DefaultAgent,
               project_root: root,
               coding_profile: "missing",
               coding_profile_resolver: resolver
             )
  end

  test "resolves exact and unique file mentions and keeps escaped literals", %{root: root} do
    setup = prepared(project_root: root)

    assert {:ok, "Review lib/value.ex and @literal", context} =
             Setup.prepare_prompt(setup, "Review @lib/value.ex and \\@literal")

    assert [%{"path" => "lib/value.ex", "content" => content}] = context["coding"]["files"]
    assert content =~ "defmodule Value"

    assert {:ok, "Review value.ex", unique_context} = Setup.prepare_prompt(setup, "Review @value.ex")
    assert [%{"path" => "lib/value.ex"}] = unique_context["coding"]["files"]
  end

  test "uses exact mention boundaries and supports quoted paths", %{root: root} do
    setup = prepared(project_root: root)

    prompt = ~s|Email dev@example.com; review (@lib/value.ex), @"lib/nested/with space.ex".|

    assert {:ok, "Email dev@example.com; review (lib/value.ex), lib/nested/with space.ex.", context} =
             Setup.prepare_prompt(setup, prompt)

    assert Enum.map(context["coding"]["files"], & &1["path"]) == [
             "lib/value.ex",
             "lib/nested/with space.ex"
           ]

    assert {:ok, "Keep foo@bar.com and @not-a-mention!", context} =
             Setup.prepare_prompt(setup, "Keep foo@bar.com and \\@not-a-mention!")

    assert context["coding"]["files"] == []

    assert {:ok, "Review lib/value.ex.", context} =
             Setup.prepare_prompt(setup, "Review @lib/value.ex.")

    assert [%{"path" => "lib/value.ex"}] = context["coding"]["files"]
  end

  test "rejects aggregate attachment count and byte limits", %{root: root} do
    for index <- 1..21 do
      File.write!(Path.join(root, "file-#{index}.txt"), "x")
    end

    setup = prepared(project_root: root)
    count_prompt = Enum.map_join(1..21, " ", &"@file-#{&1}.txt")

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_file_attachments_too_many}} =
             Setup.prepare_prompt(setup, count_prompt)

    for index <- 1..3 do
      File.write!(Path.join(root, "large-#{index}.txt"), String.duplicate("x", 800_000))
    end

    aggregate =
      prepared(
        project_root: root,
        coding_limits: %{max_file_bytes: 1_048_576, max_result_bytes: 2_097_152}
      )

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_file_attachments_too_large}} =
             Setup.prepare_prompt(aggregate, "@large-1.txt @large-2.txt @large-3.txt")
  end

  test "mention errors do not return unsafe context", %{root: root} do
    File.write!(Path.join(root, "lib/nested/value.ex"), "duplicate")
    File.write!(Path.join(root, "binary"), <<0, 1>>)
    File.write!(Path.join(root, "large"), String.duplicate("x", 1_048_577))
    setup = prepared(project_root: root)

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
               Setup.prepare_prompt(setup, prompt)
    end
  end

  defp prepared(opts) do
    opts =
      Keyword.put_new_lazy(opts, :jido_home, fn ->
        Path.join(Keyword.fetch!(opts, :project_root), "home")
      end)

    assert {:ok, setup} = Setup.prepare(Jido.Console.DefaultAgent, opts)
    on_exit(fn -> Setup.close(setup) end)
    setup
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
