defmodule Jido.Console.ExtensionsTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Extensions
  alias Jido.Console.Extensions.Record
  alias Jido.Console.Extensions.Setup
  alias Jido.Console.Extensions.Trust
  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect.{Intent, Journal}
  alias Jidoka.Extension.Request

  @hash "sha256:" <> String.duplicate("a", 64)

  setup do
    root = Path.join(System.tmp_dir!(), "jido-cli-extensions-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "resolves a user built-in record without launch data", %{root: root} do
    records = Path.join(root, "extensions.json")
    write_records(records, [built_in_record("acme.fixture")])
    request = Request.new!(id: "acme.fixture")
    factory = fn _binding, _config, _context -> {:ok, :instance, %{namespace: "acme.fixture"}} end
    resolver = fn "acme.fixture", _context -> {:ok, factory} end

    assert {:ok, setup} =
             Extensions.resolve([request],
               extension_record_files: [records],
               project_root: root,
               built_in_extension_resolver: resolver
             )

    assert Map.has_key?(Setup.registry(setup), "acme.fixture")
    projection = Setup.projection(setup)
    refute inspect(projection) =~ "command"
    refute inspect(projection) =~ root
    assert {:ok, _json} = Jason.encode(projection)
    refute Map.has_key?(setup, :registry)
    refute Map.has_key?(setup, :projection)
  end

  test "does not resolve a disabled inert request", %{root: root} do
    request = Request.new!(id: "acme.disabled", enabled: false)

    assert {:ok, setup} = Extensions.resolve([request], project_root: root)
    assert Setup.registry(setup) == %{}
    assert Setup.projection(setup) == %{"status" => "not_requested"}
  end

  test "rejects a trust record that does not own its runtime entry" do
    registration =
      Jidoka.Extension.Registration.new!(%{
        identity: %{
          id: "acme.runtime",
          source_type: :built_in,
          source_ref: "builtin:acme-runtime",
          release: "1",
          content_hash: @hash,
          trust: :trusted
        }
      })

    assert_raise ArgumentError, fn ->
      Setup.trusted([
        {%{registration: registration, factory: fn _, _, _ -> :ok end}, %{"id" => "acme.other"}}
      ])
    end
  end

  test "detects duplicate and disabled records", %{root: root} do
    records = Path.join(root, "duplicates.json")
    write_records(records, [built_in_record("acme.fixture"), built_in_record("acme.fixture")])

    assert {:error, {:duplicate_extension_record, {:user, "acme.fixture"}}} =
             Extensions.resolve([Request.new!(id: "acme.fixture")],
               extension_record_files: [records],
               project_root: root
             )

    path = Path.join(root, "disabled.json")
    write_records(path, [Map.put(built_in_record("acme.fixture"), "enabled", false)])

    assert {:error, {:extension_record_disabled, "acme.fixture"}} =
             Extensions.resolve([Request.new!(id: "acme.fixture")],
               extension_record_files: [path],
               project_root: root
             )
  end

  test "rejects missing records, invalid record files, and missing built-in resolvers", %{root: root} do
    request = Request.new!(id: "acme.fixture")

    assert {:error, {:unknown_extension_record, "acme.fixture"}} =
             Extensions.resolve([request], project_root: root)

    missing = Path.join(root, "missing.json")

    assert {:error, {:invalid_extension_record_file, ^missing, _reason}} =
             Extensions.resolve([request], extension_record_files: [missing], project_root: root)

    records = Path.join(root, "extensions.json")
    write_records(records, [built_in_record("acme.fixture")])

    assert {:error, {:built_in_extension_unavailable, "acme.fixture", false}} =
             Extensions.resolve([request], extension_record_files: [records], project_root: root)
  end

  test "validates launch commands at the record boundary", %{root: root} do
    record_path = Path.join(root, "records/extensions.json")
    built_in = built_in_record("acme.built-in")

    assert {:error, {:invalid_extension_record, ^record_path, {:error, :built_in_command_forbidden}}} =
             Record.new(Map.put(built_in, "command", ["tool"]), record_path)

    process =
      built_in
      |> Map.put("id", "acme.process")
      |> Map.put("source", "process")

    assert {:error, {:invalid_extension_record, ^record_path, {:error, :process_command_required}}} =
             Record.new(process, record_path)

    assert {:ok, normalized} =
             Record.new(Map.put(process, "command", ["bin/tool", "--safe"]), record_path)

    assert normalized.command == [Path.join(root, "records/bin/tool"), "--safe"]
  end

  test "requires canonical project trust and verifies a process executable pin", %{root: root} do
    executable = Path.join(root, "fixture-extension")
    File.write!(executable, "fixture process")
    digest = file_digest(executable)
    records = Path.join(root, "project-extensions.json")
    trust = Path.join(root, "trust.json")

    record = %{
      "id" => "acme.process",
      "source" => "process",
      "source_ref" => "registry:acme-process",
      "release" => "1.0.0",
      "sha256" => digest,
      "permissions" => ["tools"],
      "capabilities" => ["protocol.tool"],
      "scope" => "project",
      "command" => [executable]
    }

    write_records(records, [record])
    repository_id = "sha256:" <> String.duplicate("b", 64)

    File.write!(
      trust,
      Jason.encode!(%{
        "version" => 1,
        "projects" => [
          %{
            "root" => root,
            "repository_id" => repository_id,
            "extensions" => %{"acme.process" => digest}
          }
        ]
      })
    )

    descriptor_resolver = fn record, _context ->
      assert hd(record.command) == executable
      {:ok, %{transport: __MODULE__, private_command: record.command, api_key: "private"}}
    end

    opts = [
      extension_record_files: [records],
      extension_trust_file: trust,
      project_root: root,
      repository_identity: fn canonical_root ->
        assert {:ok, canonical_root} == Trust.canonical_path(root)
        {:ok, repository_id}
      end,
      process_extension_descriptor_resolver: descriptor_resolver
    ]

    assert {:ok, setup} = Extensions.resolve([Request.new!(id: "acme.process")], opts)
    refute inspect(Setup.projection(setup)) =~ executable
    refute inspect(Setup.projection(setup)) =~ "api_key"
    refute inspect(setup) =~ executable
    refute inspect(setup) =~ "api_key"

    File.write!(executable, "changed process")

    assert {:error, {:process_extension_unavailable, "acme.process", _reason}} =
             Extensions.resolve([Request.new!(id: "acme.process")], opts)
  end

  test "opens fresh public hosts with separate state and closes both", %{root: root} do
    records = Path.join(root, "fresh.json")
    write_records(records, [built_in_record("acme.fixture")])
    owner = self()

    resolver = fn _id, _context ->
      {:ok,
       fn _binding, _config, _context ->
         unique = System.unique_integer([:positive])
         send(owner, {:opened, unique})

         {:ok, unique,
          %{
            namespace: "acme.fixture",
            state: %{"instance" => unique},
            result: %{"instance" => unique},
            close: fn value ->
              send(owner, {:closed, value})
              :ok
            end
          }}
       end}
    end

    assert {:ok, setup} =
             Extensions.resolve([Request.new!(id: "acme.fixture")],
               extension_record_files: [records],
               project_root: root,
               built_in_extension_resolver: resolver
             )

    spec =
      Agent.Spec.new!(
        id: "extension_state_agent",
        instructions: "Test.",
        model: %{provider: :test, id: "model"},
        extensions: [Request.new!(id: "acme.fixture")]
      )

    {:ok, first_session} = Jidoka.Session.start(spec, "fresh-1")
    {:ok, second_session} = Jidoka.Session.start(spec, "fresh-2")
    assert {:ok, first} = Extensions.open(first_session, spec.extensions, setup)
    assert {:ok, second} = Extensions.open(second_session, spec.extensions, setup)
    assert_receive {:opened, first_id}
    assert_receive {:opened, second_id}
    assert first_id != second_id
    Extensions.close(first.host)
    Extensions.close(second.host)
    assert_receive {:closed, ^first_id}
    assert_receive {:closed, ^second_id}
  end

  test "routes extension operations, falls back, and recovers coding errors" do
    owner = self()
    request = Request.new!(id: "acme.tools")

    operations = [
      Operation.new!(name: "acme.run", idempotency: :pure),
      Operation.new!(name: "acme.fail", idempotency: :pure)
    ]

    factory = fn _binding, _config, _context ->
      {:ok, :instance,
       %{
         namespace: "acme.tools",
         tools: operations,
         tool_handlers: %{
           "acme.run" => fn arguments, _context -> {:ok, Map.fetch!(arguments, "value")} end,
           "acme.fail" => fn _arguments, _context ->
             {:error, Jidoka.CodingPack.Error.new(:write_failed, %{path: "safe.txt"})}
           end
         },
         result: %{"answer" => 42},
         ui_data: %{"panel" => "ready"},
         close: fn _instance -> send(owner, :tools_closed) end
       }}
    end

    runtime = runtime_entry("acme.tools", factory)

    setup =
      Setup.not_requested()
      |> Setup.prepend(runtime, %{"id" => "acme.tools"}, recover_coding_errors: true)

    spec =
      Agent.Spec.new!(
        id: "extension_tools_agent",
        instructions: "Test.",
        model: %{provider: :test, id: "model"},
        extensions: [request]
      )

    {:ok, session} = Jidoka.Session.Data.start(spec, session_id: "extension-tools")

    base = fn _intent, _journal, _context ->
      send(owner, :base_operation)
      {:ok, :base}
    end

    assert {:ok, opened} =
             Extensions.open(session, [request], setup, operations: base)

    capability = Keyword.fetch!(opened.runtime_opts, :operations)
    journal = Journal.new!()
    context = Jidoka.Context.new!(%{})

    assert {:ok, "value"} =
             capability.(operation_intent("acme.run", %{"value" => "value"}), journal, context)

    assert {:ok, :base} = capability.(operation_intent("base.run"), journal, context)
    assert_receive :base_operation

    assert {:ok, recovered} = capability.(operation_intent("acme.fail"), journal, context)
    assert recovered["status"] == "error"
    assert recovered["retryable"]
    assert recovered["code"] == "write_failed"
    assert recovered["details"] == %{path: "safe.txt"}

    assert {:ok, results} = Extensions.results(opened.host)

    assert results["acme.tools"] == %{
             "result" => %{"answer" => 42},
             "ui_data" => %{"panel" => "ready"}
           }

    assert {:ok, _evidence} = Extensions.close(opened.host)
    assert_receive :tools_closed
    assert {:ok, %{}} = Extensions.results(nil)
    assert {:ok, []} = Extensions.close(nil)
  end

  test "closes an opened extension when operation compilation fails" do
    owner = self()
    request = Request.new!(id: "acme.conflict")

    operation =
      Operation.new!(
        name: "acme.invalid",
        idempotency: :pure,
        metadata: %{"parameters_schema" => "not a schema"}
      )

    factory = fn _binding, _config, _context ->
      {:ok, :instance,
       %{
         namespace: "acme.conflict",
         tools: [operation],
         tool_handlers: %{"acme.invalid" => fn _, _ -> :ok end},
         close: fn _instance -> send(owner, :conflict_closed) end
       }}
    end

    setup = Setup.trusted([{runtime_entry("acme.conflict", factory), %{"id" => "acme.conflict"}}])

    spec =
      Agent.Spec.new!(
        id: "extension_conflict_agent",
        instructions: "Test.",
        model: %{provider: :test, id: "model"},
        extensions: [request]
      )

    {:ok, session} = Jidoka.Session.Data.start(spec, session_id: "extension-conflict")
    assert {:error, _reason} = Extensions.open(session, [request], setup)
    assert_receive :conflict_closed
  end

  test "requires one matching project trust record", %{root: root} do
    {:ok, canonical_root} = Trust.canonical_path(root)
    identity = %{root: canonical_root, repository_id: "repo:test"}
    trust = Path.join(root, "trust.json")

    assert {:error, {:untrusted_extension_project, ^canonical_root, "repo:test"}} =
             Trust.trusted_extensions(identity, [])

    File.write!(
      trust,
      Jason.encode!(%{
        "projects" => [
          %{"root" => Path.join(root, "missing"), "extensions" => %{}},
          %{"root" => root, "repository_id" => "repo:other", "extensions" => %{}}
        ]
      })
    )

    assert {:error, {:invalid_extension_trust, ^trust, {:error, :project_not_trusted}}} =
             Trust.trusted_extensions(identity, extension_trust_file: trust)

    project = %{"root" => root, "repository_id" => "repo:test", "extensions" => %{}}
    File.write!(trust, Jason.encode!(%{"projects" => [project, project]}))

    assert {:error, {:invalid_extension_trust, ^trust, {:error, :duplicate_project_trust}}} =
             Trust.trusted_extensions(identity, extension_trust_file: trust)
  end

  test "derives the default project identity from a canonical Git path", %{root: root} do
    git = Path.join(root, ".git")
    File.mkdir_p!(git)

    assert {:ok, identity} = Trust.project_identity(root)
    assert {:ok, identity.root} == Trust.canonical_path(root)
    assert String.starts_with?(identity.repository_id, "sha256:")
    assert byte_size(identity.repository_id) == 71
  end

  defp built_in_record(id) do
    %{
      "id" => id,
      "source" => "built_in",
      "source_ref" => "registry:#{id}",
      "release" => "1.0.0",
      "sha256" => @hash,
      "permissions" => ["state", "results"],
      "capabilities" => ["#{id}.run"],
      "scope" => "user"
    }
  end

  defp write_records(path, records) do
    File.write!(path, Jason.encode!(%{"version" => 1, "extensions" => records}))
  end

  defp file_digest(path) do
    "sha256:" <> (:crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower))
  end

  defp runtime_entry(id, factory) do
    registration =
      Jidoka.Extension.Registration.new!(%{
        identity: %{
          id: id,
          source_type: :built_in,
          source_ref: "builtin:#{id}",
          release: "1",
          content_hash: @hash,
          trust: :trusted
        },
        capabilities: ["#{id}.run"]
      })

    %{registration: registration, factory: factory}
  end

  defp operation_intent(name, arguments \\ %{}) do
    Intent.new(:operation, %{name: name, arguments: arguments})
  end
end
