defmodule Jido.Console.Release.OfflineProfile do
  @moduledoc "Provides one embedded, provider-free release acceptance profile."

  alias Jidoka.ExecutionEnvironment.{AdapterCapabilities, Registration, SecurityProfile}

  @profile_id "offline-example"
  @fixture_digest "sha256:cace48232cdf26c6b325a45a1a0074cf1994e719b09eca534e29f2c7793636b8"

  @doc false
  @spec resolve(map() | String.t(), keyword()) :: {:ok, Registration.t()} | {:error, term()}
  def resolve(%{profile_id: @profile_id}, _opts), do: registration()
  def resolve(@profile_id, _opts), do: registration()
  def resolve(%{profile_id: profile_id}, _opts), do: {:error, {:unknown_runtime_profile, profile_id}}
  def resolve(profile_id, _opts), do: {:error, {:unknown_runtime_profile, profile_id}}

  defp registration do
    with {:ok, fixture_json} <- File.read(fixture_path()) do
      profile =
        SecurityProfile.new!(
          profile_id: @profile_id,
          revision: 1,
          digest: "sha256:" <> String.duplicate("a", 64),
          adapter_id: "jido.release.offline",
          required_isolation: :container,
          required_network: :disabled,
          required_workspace: :ephemeral
        )

      capabilities =
        AdapterCapabilities.new!(
          adapter_id: "jido.release.offline",
          adapter_version: "1",
          isolations: [:container],
          networks: [:disabled],
          workspaces: [:ephemeral]
        )

      {:ok,
       Registration.new!(
         profile: profile,
         adapter: Jido.Console.Release.ForbiddenEnvironmentAdapter,
         capabilities: capabilities,
         metadata: %{
           "jido_console.replay" => %{
             "mode" => "replay",
             "fixture_json" => fixture_json,
             "fixture_digest" => @fixture_digest,
             "compatibility" => %{}
           }
         }
       )}
    end
  end

  defp fixture_path do
    :jido_console
    |> :code.priv_dir()
    |> List.to_string()
    |> Path.join("release/offline_fixture.json")
  end
end

defmodule Jido.Console.Release.ForbiddenEnvironmentAdapter do
  @moduledoc false
  @behaviour Jidoka.ExecutionEnvironment.Adapter

  for {name, arity} <- [open: 3, acquire: 2, checkpoint: 3, restore: 3, fork: 3, close: 2, cleanup: 2] do
    @doc "Rejects a live environment call while the offline release fixture runs."
    @impl true
    def unquote(name)(unquote_splicing(Macro.generate_arguments(arity, __MODULE__))) do
      raise "live environment call #{unquote(name)} is forbidden during release replay"
    end
  end
end
