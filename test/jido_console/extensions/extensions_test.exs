defmodule Jido.Console.ExtensionsTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Extensions
  alias Jido.Console.Extensions.Trust
  alias Jidoka.Agent
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

      assert Map.has_key?(setup.registry, "acme.fixture")
      projection = setup.projection
      refute inspect(projection) =~ "command"
      refute inspect(projection) =~ root
      assert {:ok, _json} = Jason.encode(projection)
    end
  end

  test "does not resolve a disabled inert request", %{root: root} do
    request = Request.new!(id: "acme.disabled", enabled: false)

    assert {:ok, %{registry: %{}, projection: %{"status" => "not_requested"}}} =
             Extensions.resolve([request], :interactive, project_root: root)
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
    refute inspect(setup.projection) =~ executable
    refute inspect(setup.projection) =~ "api_key"

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
end
