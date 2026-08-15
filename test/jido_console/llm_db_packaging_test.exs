defmodule Jido.Console.LLMDBPackagingTest do
  use ExUnit.Case, async: true

  test "production builds embed the LLMDB catalog" do
    config = Config.Reader.read!("config/config.exs", env: :prod)

    assert get_in(config, [:llm_db, :compile_embed])
  end

  test "the escript does not bundle the embedded LLMDB private directory" do
    included_priv =
      Mix.Project.config()
      |> Keyword.fetch!(:escript)
      |> Keyword.fetch!(:include_priv_for)

    refute :llm_db in included_priv
  end
end
