defmodule Jido.Console.Coding.SetupTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Coding.Setup
  alias Jido.Console.Extensions.Setup, as: ExtensionSetup
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
    assert setup.execution_policy_id == "coding.restricted"
    assert setup.context["coding"]["execution_policy_id"] == "coding.restricted"
    assert setup.context["coding"]["pack_id"] == "jido.coding_pack"
    assert setup.context["jido_console"]["execution_policy"] == %{"id" => "coding.restricted"}
    refute inspect(setup.context) =~ "credential"
    refute inspect(setup.context) =~ "adapter"

    assert setup.local_resources.environment_contract === setup.environment_contract
    assert setup.local_resources.binding.profile_id == setup.environment_contract.execution_policy_id

    assert setup.local_resources.environment_evidence.facts["environment_contract_digest"] ==
             Jido.Console.Coding.Environment.digest(setup.environment_contract)

    assert setup.spec.id == "jido"
    assert Enum.any?(setup.spec.extensions, &(&1.id == "jido.coding_pack"))
    assert Map.has_key?(ExtensionSetup.registry(setup.extension_setup), "jido.coding_pack")

    assert ExtensionSetup.projection(setup.extension_setup) == %{
             "status" => "trusted",
             "records" => [%{"id" => "jido.coding_pack", "source" => "built_in"}]
           }

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

    assert setup.spec.instructions =~
             "For a repository overview, inspect the repository instead of answering from project instructions alone."

    assert setup.spec.instructions =~
             "Start with a root path search, then read the README and the main build manifest when they exist."

    assert setup.spec.instructions =~
             "For a normal text read, omit byte offsets and lengths unless you continue a truncated result."
  end

  test "can disable the full pack or replace it by a trusted ID", %{root: root} do
    disabled = prepared(project_root: root, coding_pack: :disabled)

    assert disabled.pack_id == nil

    assert {:ok, "Keep @literal", %{"coding" => %{"status" => "disabled"}}} =
             Setup.prepare_prompt(disabled, "Keep \\@literal")

    assert {:ok, "Keep @client", %{"coding" => %{"status" => "disabled"}}} =
             disabled
             |> Setup.client_setup()
             |> Setup.prepare_prompt("Keep \\@client")

    assert ExtensionSetup.projection(disabled.extension_setup) == %{
             "status" => "disabled",
             "other_extensions" => %{"status" => "not_requested"}
           }

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
    assert Map.has_key?(ExtensionSetup.registry(replacement.extension_setup), "acme.coding_pack")
  end

  test "closes local resources when coding-pack configuration is rejected", %{root: root} do
    {:links, before_links} = Process.info(self(), :links)

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_tool_entries_invalid}} =
             Setup.prepare(Jido.Console.DefaultAgent,
               project_root: root,
               coding_replace_tools: "invalid"
             )

    {:links, after_links} = Process.info(self(), :links)
    assert MapSet.new(after_links) == MapSet.new(before_links)
  end

  test "closes local resources when an extension resolver raises or throws", %{root: root} do
    request = Jidoka.Extension.Request.new!(id: "acme.failure")
    base = Jido.Console.DefaultAgent.spec()

    {:ok, agent} =
      Jidoka.Agent.Spec.new(%{
        base
        | extensions: [request | Enum.reject(base.extensions, &(&1.id == request.id))]
      })

    opts = [project_root: root, extension_record_files: [record(root, "acme.failure")]]

    {:links, before_raise} = Process.info(self(), :links)

    assert_raise RuntimeError, "resolver failed", fn ->
      Setup.prepare(
        agent,
        Keyword.put(opts, :built_in_extension_resolver, fn _id, _context ->
          raise "resolver failed"
        end)
      )
    end

    {:links, after_raise} = Process.info(self(), :links)
    assert MapSet.new(after_raise) == MapSet.new(before_raise)

    assert :resolver_threw =
             catch_throw(
               Setup.prepare(
                 agent,
                 Keyword.put(opts, :built_in_extension_resolver, fn _id, _context ->
                   throw(:resolver_threw)
                 end)
               )
             )

    {:links, after_throw} = Process.info(self(), :links)
    assert MapSet.new(after_throw) == MapSet.new(before_raise)
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

    entry = ExtensionSetup.registry(setup.extension_setup)["jido.coding_pack"]
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
    assert {:error, :invalid_coding_agent} = Setup.prepare(%{}, project_root: root)

    assert {:error, :coding_module_name_forbidden} =
             Setup.prepare(Jido.Console.DefaultAgent, project_root: root, coding_pack: "Elixir.Raw.Module")

    assert {:error, {:invalid_coding_pack, 42}} =
             Setup.prepare(Jido.Console.DefaultAgent, project_root: root, coding_pack: 42)

    resolver = fn _id -> {:error, :missing} end

    assert {:error, {:unknown_execution_policy, "missing"}} =
             Setup.prepare(Jido.Console.DefaultAgent,
               project_root: root,
               coding_profile: "missing",
               coding_profile_resolver: resolver
             )
  end

  test "rejects unavailable restricted enforcement without an unisolated fallback", %{root: root} do
    original_path = System.get_env("PATH")
    System.put_env("PATH", "")

    try do
      assert {:error, :local_coding_executable_missing} =
               Setup.prepare(Jido.Console.DefaultAgent,
                 project_root: root,
                 jido_home: Path.join(root, "home-without-local-tools")
               )
    after
      if original_path, do: System.put_env("PATH", original_path), else: System.delete_env("PATH")
    end
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

  test "projects only bounded client setup data and resolves client file mentions", %{root: root} do
    setup = prepared(project_root: root)
    client = Setup.client_setup(setup)

    assert client.workspace == setup.workspace
    assert client.instructions == setup.instructions
    assert client.context == setup.context
    assert client.await_timeout_ms == setup.await_timeout_ms
    assert client.turn_opts == setup.turn_opts
    refute Map.has_key?(Map.from_struct(client), :local_resources)

    assert {:ok, "Review lib/value.ex", context} =
             Setup.prepare_prompt(client, "Review @lib/value.ex")

    assert [%{"path" => "lib/value.ex", "content" => content}] = context["coding"]["files"]
    assert content =~ "defmodule Value"
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
          "scope" => "user"
        }
      ]
    }

    File.write!(path, Jason.encode!(document))
    path
  end
end
