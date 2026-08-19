defmodule Jido.Console.Credential.ProfileSchemaTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Credential.ProfileSchema

  test "declared environment, private dotenv, and keychain identities pass without values" do
    for reference <- [environment_reference(), dotenv_reference(), keychain_reference()] do
      assert :ok = ProfileSchema.validate(profile([reference]))
    end
  end

  test "values, fingerprints, locators, shell text, and unknown metadata fail" do
    cases = [
      put_in(profile([environment_reference()]), ["api_key"], "CANARY_DO_NOT_STORE"),
      put_in(profile([environment_reference()]), ["references", Access.at(0), "value_fingerprint"], "sha256:x"),
      put_in(profile([environment_reference()]), ["references", Access.at(0), "lookup", "uri"], "env://OPENAI"),
      put_in(profile([environment_reference()]), ["references", Access.at(0), "lookup", "name"], "--token=value"),
      put_in(profile([environment_reference()]), ["references", Access.at(0), "lookup", "name"], "${SERVICE_TOKEN}")
    ]

    for candidate <- cases do
      assert {:error, _reason} = ProfileSchema.validate(candidate)
    end
  end

  test "duplicate, unsupported, unbounded, and oversized references fail" do
    reference = environment_reference()

    assert {:error, {:duplicate_credential_reference, "environment-fixture"}} =
             ProfileSchema.validate(profile([reference, reference]))

    unsupported = Map.put(reference, "kind", "remote_vault")

    assert {:error, {:unsupported_credential_source, "remote_vault"}} =
             ProfileSchema.validate(profile([unsupported]))

    assert {:error, :credential_reference_limit} =
             0..8
             |> Enum.map(fn index -> Map.put(reference, "reference_id", "reference-#{index}") end)
             |> profile()
             |> ProfileSchema.validate()

    oversized = String.duplicate("a", 16_384)

    assert {:error, {:oversized_credential_metadata, size, 16_384}} =
             profile([Map.put(reference, "source_identity", oversized)]) |> ProfileSchema.validate()

    assert size > 16_384
  end

  test "missing and invalid identities fail with typed metadata errors" do
    reference = environment_reference()

    assert {:error, :invalid_credential_profile} = ProfileSchema.validate(nil)

    assert {:error, :invalid_credential_profile_id} =
             profile([reference]) |> Map.put("profile_id", "") |> ProfileSchema.validate()

    assert {:error, :invalid_credential_references} =
             profile([reference]) |> Map.put("references", nil) |> ProfileSchema.validate()

    assert {:error, :invalid_credential_reference_id} =
             reference
             |> Map.put("reference_id", "")
             |> then(&profile([&1]))
             |> ProfileSchema.validate()

    assert {:error, :invalid_credential_reference_source} =
             reference
             |> Map.put("source_identity", "")
             |> then(&profile([&1]))
             |> ProfileSchema.validate()

    assert {:error, {:missing_credential_profile_fields, ["profile_id"]}} =
             profile([reference]) |> Map.delete("profile_id") |> ProfileSchema.validate()

    assert {:error, :invalid_credential_reference} =
             profile([:not_a_reference]) |> ProfileSchema.validate()
  end

  defp profile(references) do
    %{
      "profile_id" => "profile-fixture",
      "profile_version" => 1,
      "source_identity" => "host-fixture",
      "references" => references
    }
  end

  defp environment_reference do
    %{
      "reference_id" => "environment-fixture",
      "kind" => "environment",
      "source_identity" => "host-fixture",
      "lookup" => %{"name" => "OPENAI_API_KEY"}
    }
  end

  defp dotenv_reference do
    %{
      "reference_id" => "dotenv-fixture",
      "kind" => "private_dotenv",
      "source_identity" => "host-fixture",
      "lookup" => %{
        "file_identity" => "sha256:" <> String.duplicate("b", 64),
        "variable" => "ANTHROPIC_API_KEY"
      }
    }
  end

  defp keychain_reference do
    %{
      "reference_id" => "keychain-fixture",
      "kind" => "keychain_item",
      "source_identity" => "host-fixture",
      "lookup" => %{
        "item_identity" => "keychain-item-fixture",
        "service" => "jido-fixture",
        "account" => "provider-fixture"
      }
    }
  end
end
