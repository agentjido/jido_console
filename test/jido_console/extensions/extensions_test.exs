defmodule Jido.Console.ExtensionsTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Extensions
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

  test "resolves a user built-in record in both modes without launch data", %{root: root} do
    records = Path.join(root, "extensions.json")
    write_records(records, [built_in_record("acme.fixture")])
    request = Request.new!(id: "acme.fixture")
    factory = fn _binding, _config, _context -> {:ok, :instance, %{namespace: "acme.fixture"}} end
    resolver = fn "acme.fixture", _context -> {:ok, factory} end

    for mode <- [:interactive, :automation] do
      assert {:ok, setup} =
               Extensions.resolve([request], mode,
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
  end

  test "does not resolve a disabled inert request", %{root: root} do
    request = Request.new!(id: "acme.disabled", enabled: false)

    assert {:ok, setup} = Extensions.resolve([request], :interactive, project_root: root)
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

  test "detects duplicates, disabled records, and interactive-only automation", %{root: root} do
    records = Path.join(root, "duplicates.json")
    write_records(records, [built_in_record("acme.fixture"), built_in_record("acme.fixture")])

    assert {:error, {:duplicate_extension_record, {:user, "acme.fixture"}}} =
             Extensions.resolve([Request.new!(id: "acme.fixture")], :interactive,
               extension_record_files: [records],
               project_root: root
             )

    for {overrides, expected} <- [
          {%{"enabled" => false}, :extension_record_disabled},
          {%{"modes" => ["interactive"]}, :extension_mode_not_allowed}
        ] do
      path = Path.join(root, "invalid-#{expected}.json")
      write_records(path, [Map.merge(built_in_record("acme.fixture"), overrides)])

      assert {:error, reason} =
               Extensions.resolve([Request.new!(id: "acme.fixture")], :automation,
                 extension_record_files: [path],
                 project_root: root
               )

      assert elem(reason, 0) == expected
    end
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
      "modes" => ["automation"],
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

    assert {:ok, setup} = Extensions.resolve([Request.new!(id: "acme.process")], :automation, opts)
    refute inspect(Setup.projection(setup)) =~ executable
    refute inspect(Setup.projection(setup)) =~ "api_key"
    refute inspect(setup) =~ executable
    refute inspect(setup) =~ "api_key"

    File.write!(executable, "changed process")

    assert {:error, {:process_extension_unavailable, "acme.process", _reason}} =
             Extensions.resolve([Request.new!(id: "acme.process")], :automation, opts)
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
             Extensions.resolve([Request.new!(id: "acme.fixture")], :automation,
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
    assert {:ok, first} = Extensions.open(first_session, spec.extensions, setup, :automation)
    assert {:ok, second} = Extensions.open(second_session, spec.extensions, setup, :automation)
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
             Extensions.open(session, [request], setup, :interactive, operations: base)

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
    assert {:error, _reason} = Extensions.open(session, [request], setup, :interactive)
    assert_receive :conflict_closed
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
      "modes" => ["interactive", "automation"],
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
