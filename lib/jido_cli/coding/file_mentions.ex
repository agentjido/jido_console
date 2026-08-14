defmodule Jido.Cli.Coding.FileMentions do
  @moduledoc "Deterministic `@file` parsing through Jidoka workspace read and search services."

  alias Jido.Cli.Terminal.PlainText
  alias Jidoka.CodingPack.{Error, Read, Search, Workspace}

  @mention ~r/(?<![\p{L}\p{N}_@\\])(?<full>@(?:"(?<double>(?:\\.|[^"\\\r\n])*)"|'(?<single>(?:\\.|[^'\\\r\n])*)'|(?<bare>[\p{L}\p{N}._\/~+#=-]*[\p{L}\p{N}_~+#=-])))/u
  @max_files 20
  @max_total_bytes 2_097_152

  @doc "Resolves all exact file mentions and removes mention syntax from the prompt."
  @spec resolve(Workspace.t(), String.t()) :: {:ok, String.t(), [map()]} | {:error, term()}
  def resolve(%Workspace{} = workspace, prompt) when is_binary(prompt) do
    prompt = PlainText.clean(prompt)
    mentions = prompt |> matches() |> Enum.map(& &1.path) |> Enum.uniq()

    with :ok <- check_count(mentions),
         {:ok, files} <- resolve_mentions(workspace, mentions) do
      prompt = prompt |> replace_mentions() |> String.replace("\\@", "@")
      {:ok, prompt, files}
    end
  end

  defp matches(prompt) do
    Regex.scan(@mention, prompt, capture: ["full", "double", "single", "bare"], return: :index)
    |> Enum.map(fn [full, double, single, bare] ->
      %{full: full, path: capture(prompt, [double, single, bare])}
    end)
  end

  defp capture(prompt, captures) do
    captures
    |> Enum.find(fn {start, _length} -> start >= 0 end)
    |> then(fn {start, length} -> binary_part(prompt, start, length) end)
    |> String.replace(~r/\\(["'\\])/u, "\\1")
  end

  defp replace_mentions(prompt) do
    {parts, offset} =
      Enum.reduce(matches(prompt), {[], 0}, fn %{full: {start, length}, path: path}, {parts, offset} ->
        prefix = binary_part(prompt, offset, start - offset)
        {[parts, prefix, path], start + length}
      end)

    IO.iodata_to_binary([parts, binary_part(prompt, offset, byte_size(prompt) - offset)])
  end

  defp check_count(mentions) when length(mentions) <= @max_files, do: :ok

  defp check_count(mentions) do
    {:error,
     Error.new(:coding_file_attachments_too_many, %{
       count: length(mentions),
       max_files: @max_files
     })}
  end

  defp resolve_mentions(workspace, mentions) do
    Enum.reduce_while(mentions, {:ok, [], 0}, fn mention, {:ok, files, total_bytes} ->
      case resolve_one(workspace, mention) do
        {:ok, file} ->
          total_bytes = total_bytes + Map.get(file, "size", 0)

          if total_bytes <= @max_total_bytes do
            {:cont, {:ok, files ++ [file], total_bytes}}
          else
            {:halt,
             {:error,
              Error.new(:coding_file_attachments_too_large, %{
                total_bytes: total_bytes,
                max_total_bytes: @max_total_bytes
              })}}
          end

        {:error, reason} ->
          {:halt, {:error, {:file_mention_failed, mention, reason}}}
      end
    end)
    |> case do
      {:ok, files, _total_bytes} -> {:ok, files}
      {:error, _reason} = error -> error
    end
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
