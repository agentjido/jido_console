defmodule Jido.Console.Tui.Command do
  @moduledoc """
  Pure slash-command parsing and discovery for the terminal interface.

  A leading slash always creates a command attempt. Invalid attempts return an
  error and never become prompts.
  """

  alias Jido.Console.Error

  @type action ::
          :help
          | :cancel
          | :show_agent
          | :list_models
          | :list_execution_policies
          | :list_profiles
          | :new_session
          | {:select_agent, String.t()}
          | {:select_model, String.t()}
          | {:select_execution_policy, String.t()}
          | {:select_profile, String.t()}

  @commands [
    %{name: "help", usage: "/help", summary: "Show slash commands", argument: :none, action: :help},
    %{
      name: "agent",
      usage: "/agent [source]",
      summary: "Show or select an agent source",
      argument: :remainder,
      action: :agent
    },
    %{
      name: "execution-policy",
      usage: "/execution-policy [id]",
      summary: "Show or select an execution policy",
      argument: :optional,
      action: :execution_policy
    },
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
      summary: "Deprecated alias for /execution-policy",
      argument: :optional,
      action: :profile
    },
    %{
      name: "new-session",
      usage: "/new-session",
      summary: "Create a clean thread after blocked resume",
      argument: :none,
      action: :new_session
    },
    %{
      name: "cancel",
      usage: "/cancel",
      summary: "Close a blocked read-only thread",
      argument: :none,
      action: :cancel
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
    [token | remainder] = String.split(input, ~r/[\t ]+/, parts: 2, trim: true)
    name = String.trim_leading(token, "/")
    remainder = remainder |> List.first("") |> String.trim()

    with true <- valid_token?(token, name),
         command when not is_nil(command) <- Enum.find(@commands, &(&1.name == name)) do
      parse_arguments(command, remainder)
    else
      _other -> unknown(token)
    end
  end

  defp valid_token?("/" <> name, name), do: name != "" and not String.starts_with?(name, "/")
  defp valid_token?(_token, _name), do: false

  defp parse_arguments(%{argument: :none, action: action}, ""), do: {:command, action}

  defp parse_arguments(%{argument: :none, usage: usage}, _remainder),
    do: error("Usage: #{usage}")

  defp parse_arguments(%{action: :agent}, ""), do: {:command, :show_agent}
  defp parse_arguments(%{action: :agent}, source), do: {:command, {:select_agent, source}}
  defp parse_arguments(%{action: :model}, ""), do: {:command, :list_models}

  defp parse_arguments(%{action: :model, usage: usage}, identity) do
    one_token({:select_model, identity}, identity, usage)
  end

  defp parse_arguments(%{action: :execution_policy}, ""), do: {:command, :list_execution_policies}

  defp parse_arguments(%{action: :execution_policy, usage: usage}, id) do
    one_token({:select_execution_policy, id}, id, usage)
  end

  defp parse_arguments(%{action: :profile}, ""), do: {:command, :list_profiles}

  defp parse_arguments(%{action: :profile, usage: usage}, id) do
    one_token({:select_profile, id}, id, usage)
  end

  defp one_token(action, value, usage) do
    if String.contains?(value, [" ", "\t"]),
      do: error("Usage: #{usage}"),
      else: {:command, action}
  end

  defp unknown(token) do
    commands = @commands |> Enum.map_join(", ", &String.replace_prefix(&1.usage, " [", ""))
    error("Unknown command #{token}. Available commands: #{commands}")
  end

  defp error(message), do: {:error, Error.validation_error(message, %{source: :slash_command})}
end
