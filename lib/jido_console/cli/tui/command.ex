defmodule Jido.Console.Tui.Command do
  @moduledoc """
  Pure slash-command parsing and discovery for the terminal interface.

  A leading slash always creates a command attempt. Invalid attempts return an
  error and never become prompts.
  """

  alias Jido.Console.Error

  @type action ::
          :help
          | :list_models
          | :list_profiles
          | {:select_model, String.t()}
          | {:select_profile, String.t()}

  @commands [
    %{name: "help", usage: "/help", summary: "Show slash commands", argument: :none, action: :help},
    %{
      name: "model",
      usage: "/model [provider:model]",
      summary: "List or select a model",
      argument: :optional,
      argument_source: :models,
      action: :model
    },
    %{
      name: "profile",
      usage: "/profile [profile]",
      summary: "List profile compatibility options",
      argument: :optional,
      action: :profile
    }
  ]

  @doc "Parses one submitted input into a prompt, command action, or command error."
  @spec parse(String.t()) :: :prompt | {:command, action()} | {:error, Exception.t()}
  def parse(input) when is_binary(input) do
    trimmed = String.trim(input)

    cond do
      not String.starts_with?(trimmed, "/") ->
        :prompt

      String.contains?(input, ["\n", "\r"]) ->
        error("Slash commands must use one line")

      true ->
        parse_attempt(trimmed)
    end
  end

  @doc "Returns stable help text generated from the command registry."
  @spec help() :: String.t()
  def help do
    @commands
    |> Enum.sort_by(& &1.usage)
    |> Enum.map_join("\n", fn command -> "#{command.usage} — #{command.summary}" end)
  end

  @doc "Returns the registered command descriptors."
  @spec registry() :: [map()]
  def registry, do: @commands

  defp parse_attempt(input) do
    parts = String.split(input, ~r/[\t ]+/, trim: true)
    [token | arguments] = parts
    name = String.trim_leading(token, "/")

    with true <- valid_token?(token, name),
         command when not is_nil(command) <- Enum.find(@commands, &(&1.name == name)) do
      parse_arguments(command, arguments)
    else
      _other -> unknown(token)
    end
  end

  defp valid_token?("/" <> name, name), do: name != "" and not String.starts_with?(name, "/")
  defp valid_token?(_token, _name), do: false

  defp parse_arguments(%{argument: :none, action: action}, []), do: {:command, action}

  defp parse_arguments(%{argument: :none, usage: usage}, _arguments),
    do: error("Usage: #{usage}")

  defp parse_arguments(%{action: :model}, []), do: {:command, :list_models}
  defp parse_arguments(%{action: :model}, [identity]), do: {:command, {:select_model, identity}}
  defp parse_arguments(%{action: :profile}, []), do: {:command, :list_profiles}
  defp parse_arguments(%{action: :profile}, [profile]), do: {:command, {:select_profile, profile}}
  defp parse_arguments(%{usage: usage}, _arguments), do: error("Usage: #{usage}")

  defp unknown(token) do
    commands = @commands |> Enum.map_join(", ", &String.replace_prefix(&1.usage, " [", ""))
    error("Unknown command #{token}. Available commands: #{commands}")
  end

  defp error(message), do: {:error, Error.validation_error(message, %{source: :slash_command})}
end
