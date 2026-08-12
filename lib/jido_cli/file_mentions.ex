defmodule Jido.Cli.FileMentions do
  @moduledoc "Deterministic `@file` parsing through Jidoka workspace read and search services."

  alias Jidoka.CodingPack.{Error, Read, Search, Workspace}

  @mention ~r/(?<!\\)@([^\s]+)/u

  @doc "Resolves all exact file mentions and removes mention syntax from the prompt."
  @spec resolve(Workspace.t(), String.t()) :: {:ok, String.t(), [map()]} | {:error, term()}
  def resolve(%Workspace{} = workspace, prompt) when is_binary(prompt) do
    mentions = Regex.scan(@mention, prompt, capture: :all_but_first) |> List.flatten() |> Enum.uniq()

    with {:ok, files} <- resolve_mentions(workspace, mentions) do
      prompt = prompt |> String.replace(@mention, "\\1") |> String.replace("\\@", "@")
      {:ok, prompt, files}
    end
  end

  defp resolve_mentions(workspace, mentions) do
    Enum.reduce_while(mentions, {:ok, []}, fn mention, {:ok, files} ->
      case resolve_one(workspace, mention) do
        {:ok, file} -> {:cont, {:ok, files ++ [file]}}
        {:error, reason} -> {:halt, {:error, {:file_mention_failed, mention, reason}}}
      end
    end)
  end

  defp resolve_one(workspace, mention) do
    if safe_mention?(mention) do
      case Read.run(workspace, %{"path" => mention}) do
        {:ok, result} -> {:ok, project(result)}
        {:error, %Error{code: :coding_file_not_found}} -> search_one(workspace, mention)
        {:error, %Error{} = error} -> {:error, error}
      end
    else
      {:error, Error.new(:coding_file_mention_invalid)}
    end
  end

  defp search_one(workspace, mention) do
    with {:ok, search} <-
           Search.run(workspace, %{
             "mode" => "path",
             "path" => ".",
             "pattern" => mention,
             "glob" => "**/#{mention}",
             "max_results" => 3
           }),
         {:ok, path} <- one_match(search["matches"], mention),
         {:ok, result} <- Read.run(workspace, %{"path" => path}) do
      {:ok, project(result)}
    end
  end

  defp one_match([%{"path" => path, "type" => "regular"}], _mention), do: {:ok, path}
  defp one_match([], mention), do: {:error, Error.new(:coding_file_mention_missing, %{mention: mention})}

  defp one_match(matches, mention),
    do: {:error, Error.new(:coding_file_mention_ambiguous, %{mention: mention, matches: matches})}

  defp project(result),
    do: Map.take(result, ["path", "content", "sha256", "size", "truncated", "ignore"])

  defp safe_mention?(mention) do
    mention != "" and String.valid?(mention) and not String.contains?(mention, ["*", "?", "[", "]", <<0>>])
  end
end
