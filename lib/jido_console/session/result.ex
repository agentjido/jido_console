defmodule Jido.Console.Session.Result do
  @moduledoc """
  Separates concise model content from typed view details.
  """

  @type t :: %{content: String.t() | nil, view: map(), sensitivity: String.t(), durability: String.t(), trust: map()}

  @doc "Builds a model/view result pair."
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) do
    view = Keyword.get(opts, :view, %{})

    if renderer_value?(view) do
      {:error, :renderer_value_forbidden}
    else
      {:ok,
       %{
         content: Keyword.get(opts, :content),
         view: view,
         sensitivity: Keyword.get(opts, :sensitivity, "public"),
         durability: Keyword.get(opts, :durability, "process"),
         trust: Keyword.get(opts, :trust, %{evidence: "worker", policy: "session-owner"})
       }}
    end
  end

  @doc "Returns protocol fields with content and view separated."
  @spec to_protocol(t()) :: map()
  def to_protocol(result) do
    %{
      "content" => result.content,
      "view" => stringify(result.view),
      "sensitivity" => result.sensitivity,
      "durability" => result.durability,
      "trust" => result.trust
    }
  end

  defp renderer_value?(value) when is_pid(value) or is_reference(value) or is_function(value), do: true

  defp renderer_value?(value) when is_map(value) do
    Enum.any?(value, fn {key, item} ->
      key in [:ansi, "ansi", :dom, "dom"] or renderer_value?(item)
    end)
  end

  defp renderer_value?(value) when is_list(value), do: Enum.any?(value, &renderer_value?/1)
  defp renderer_value?(_value), do: false

  defp stringify(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
