defmodule Jido.Console.Models do
  @moduledoc """
  Validated model support catalog used by commands and the TUI.

  Support tiers are `supported`, `beta`, `available`, and `unsupported`.
  Missing contract evidence cannot be presented as a supported feature.
  """

  alias Jido.Console.Models.Catalog

  @doc "Returns the current catalog revision identifier."
  @spec revision() :: String.t()
  def revision, do: Catalog.revision()

  @doc "Loads and validates the v0.1 model catalog."
  @spec load(keyword()) :: {:ok, Catalog.t()} | {:error, term()}
  def load(opts \\ []), do: Catalog.load(opts)

  @doc "Lists catalog entries after validation."
  @spec list(keyword()) :: {:ok, [Catalog.entry()]} | {:error, term()}
  def list(opts \\ []) do
    with {:ok, catalog} <- load(opts) do
      {:ok, catalog.entries}
    end
  end

  @doc "Shows one catalog entry by provider and model identity."
  @spec show(String.t(), String.t(), keyword()) :: {:ok, Catalog.entry()} | {:error, term()}
  def show(provider, model, opts \\ []) do
    with {:ok, catalog} <- load(opts) do
      Catalog.fetch(catalog, provider, model)
    end
  end
end
