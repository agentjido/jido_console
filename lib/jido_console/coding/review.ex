defmodule Jido.Console.Coding.Review do
  @moduledoc "Validation and redaction boundary for coding review projections."

  @max_records 50
  @max_patch_bytes 8_192
  @statuses ~w(changed no_change conflict interrupted restored restore_failed failed cancelled)
  @sensitive_names ~w(.env .env.local credentials secrets id_rsa id_ed25519)

  @type candidate :: map()
  @type projection :: map()

  @doc "Extracts raw review candidates from a public Jidoka session result."
  @spec candidates_from_session(term()) :: [candidate()]
  def candidates_from_session(%Jidoka.Session.Data{result: %Jidoka.Turn.Result{} = result}) do
    request_id = result_request_id(result)

    result.agent_state.operation_results
    |> Enum.filter(&(is_nil(request_id) or &1.request_id == request_id))
    |> Enum.flat_map(&operation_review/1)
  end

  def candidates_from_session(_session), do: []

  @doc "Validates and redacts raw review candidates into bounded projections."
  @spec project_candidates(term()) :: [projection()]
  def project_candidates(records) when is_list(records) do
    records
    |> Enum.take(@max_records)
    |> Enum.flat_map(&normalize_record/1)
    |> Enum.sort_by(&{&1["path"] || "", &1["operation_id"] || "", &1["kind"]})
  end

  def project_candidates(_records), do: []

  defp operation_review(%Jidoka.Effect.OperationResult{operation: operation, output: output})
       when operation in ["coding.write", "coding.edit"] and is_map(output),
       do: [Map.put(stringify_keys(output), "kind", "edit")]

  defp operation_review(%Jidoka.Effect.OperationResult{operation: "coding.git_diff", output: output})
       when is_map(output),
       do: [Map.put(stringify_keys(output), "kind", "git_diff")]

  defp operation_review(_result), do: []

  defp normalize_record(record) when is_map(record) do
    record = stringify_keys(record)

    case record["kind"] do
      "edit" -> normalize_edit(record)
      "git_diff" -> normalize_diff(record)
      "mutation_state" -> normalize_state(record)
      "checkpoint" -> normalize_state(record)
      _unknown -> []
    end
  end

  defp normalize_record(_record), do: []

  defp normalize_edit(record) do
    path = safe_path(record["path"])
    status = Map.get(record, "status", "changed")
    checkpoint = get_in(record, ["checkpoint", "checkpoint_ref"])

    if not is_nil(path) and status in @statuses and valid_digest?(record["after_sha256"]) and safe_ref?(checkpoint) do
      sensitive = sensitive?(path)

      [
        %{
          "kind" => "edit",
          "path" => if(sensitive, do: "[redacted]", else: path),
          "operation" => safe_text(record["action"], 32),
          "operation_id" => safe_text(record["operation_id"], 128),
          "status" => status,
          "before_sha256" => short_digest(record["before_sha256"]),
          "after_sha256" => short_digest(record["after_sha256"]),
          "checkpoint_ref" => checkpoint,
          "diff" => if(sensitive, do: %{"redacted" => true}, else: structural_diff(record["diff"])),
          "truncated" => false
        }
      ]
    else
      []
    end
  end

  defp normalize_diff(record) do
    files = normalize_files(record["files"])
    status = diff_status(record["status"], files)
    sensitive = Enum.any?(files, & &1["redacted"])
    patch = if sensitive, do: "[redacted sensitive diff]", else: safe_patch(record["patch"])

    truncated =
      record["truncated"] == true or (is_binary(record["patch"]) and byte_size(record["patch"]) > byte_size(patch))

    if status in @statuses and is_binary(patch) do
      [
        %{
          "kind" => "git_diff",
          "path" => nil,
          "operation" => "git diff",
          "operation_id" => nil,
          "status" => status,
          "files" => files,
          "patch" => patch,
          "binary" => Enum.any?(files, & &1["binary"]),
          "truncated" => truncated,
          "checkpoint_ref" => nil
        }
      ]
    else
      []
    end
  end

  defp normalize_state(record) do
    status = record["status"]
    path = safe_path(record["path"])
    checkpoint = record["checkpoint_ref"]

    if status in @statuses and (is_nil(record["path"]) or not is_nil(path)) and safe_ref?(checkpoint) do
      [
        %{
          "kind" => record["kind"],
          "path" => if(not is_nil(path) and sensitive?(path), do: "[redacted]", else: path),
          "operation" => safe_text(record["operation"], 32),
          "operation_id" => safe_text(record["operation_id"], 128),
          "status" => status,
          "checkpoint_ref" => checkpoint,
          "message" => safe_text(record["message"], 256),
          "truncated" => false
        }
      ]
    else
      []
    end
  end

  defp normalize_files(files) when is_list(files) do
    files
    |> Enum.take(@max_records)
    |> Enum.flat_map(fn file ->
      file = if is_map(file), do: stringify_keys(file), else: %{}

      case safe_path(file["path"]) do
        nil ->
          []

        path ->
          sensitive = sensitive?(path)

          [
            %{
              "path" => if(sensitive, do: "[redacted]", else: path),
              "binary" => file["binary"] == true,
              "additions" => nonnegative(file["additions"]),
              "deletions" => nonnegative(file["deletions"]),
              "redacted" => sensitive
            }
          ]
      end
    end)
    |> Enum.sort_by(& &1["path"])
  end

  defp normalize_files(_files), do: []

  defp structural_diff(diff) when is_map(diff) do
    diff = stringify_keys(diff)

    Map.take(diff, [
      "before_lines",
      "after_lines",
      "changed_before_lines",
      "changed_after_lines",
      "common_prefix_lines",
      "common_suffix_lines"
    ])
    |> Map.new(fn {key, value} -> {key, nonnegative(value)} end)
  end

  defp structural_diff(_diff), do: %{}

  defp safe_path(path) when is_binary(path) do
    if path != "" and Path.type(path) == :relative and not Enum.any?(Path.split(path), &(&1 == "..")) and
         String.valid?(path) and not control_char?(path) and not Regex.match?(~r/\A[A-Za-z]:[\\\/]/, path),
       do: String.replace(path, "\\", "/"),
       else: nil
  end

  defp safe_path(_path), do: nil

  defp sensitive?(path) do
    basename = String.downcase(Path.basename(path))

    basename in @sensitive_names or String.ends_with?(basename, [".pem", ".key"]) or
      String.contains?(String.downcase(path), ["secret", "credential"])
  end

  defp safe_patch(value) when is_binary(value) do
    if String.valid?(value),
      do: value |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, "�") |> utf8_prefix(@max_patch_bytes),
      else: ""
  end

  defp safe_patch(_value), do: ""

  defp utf8_prefix(value, limit) when byte_size(value) <= limit, do: value

  defp utf8_prefix(value, limit) do
    candidate = binary_part(value, 0, limit)
    if String.valid?(candidate), do: candidate, else: utf8_prefix(value, limit - 1)
  end

  defp valid_digest?("sha256:" <> digest), do: byte_size(digest) == 64 and digest =~ ~r/\A[0-9a-f]+\z/
  defp valid_digest?(_digest), do: false
  defp short_digest(nil), do: nil
  defp short_digest("sha256:" <> digest), do: "sha256:" <> binary_part(digest, 0, 12)
  defp short_digest(_digest), do: nil
  defp safe_ref?(nil), do: true

  defp safe_ref?(value) do
    is_binary(value) and value != "" and not control_char?(value) and
      not String.starts_with?(value, ["/", "~/", "file:"])
  end

  defp safe_text(nil, _limit), do: nil

  defp safe_text(value, limit) when is_binary(value) and byte_size(value) <= limit do
    if String.valid?(value) and not control_char?(value), do: value, else: nil
  end

  defp safe_text(_value, _limit), do: nil
  defp nonnegative(nil), do: nil
  defp nonnegative(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative(_value), do: nil
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp diff_status(_status, []), do: "no_change"
  defp diff_status(status, _files) when status in [nil, "ok"], do: "changed"
  defp diff_status(status, _files), do: status

  defp result_request_id(%Jidoka.Turn.Result{metadata: metadata}) do
    get_in(metadata, [:debug, :request_id]) || get_in(metadata, ["debug", "request_id"])
  end

  defp control_char?(value), do: Regex.match?(~r/[\x00-\x1F\x7F]/u, value)
end
