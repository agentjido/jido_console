# Jido Console Guide

Jido Console accepts normal prompts and a small set of slash commands in the
same input area. A slash command controls the local Console session. It is not
sent to the model and it is not saved in the conversation or thread history.

## Commands

Use `/help` to show the command list. Command names use lower-case text and do
not have canonical aliases.

| Command | Result |
| --- | --- |
| `/help` | Show the command list. |
| `/agent` | Show the current agent ID, source kind, safe label, and content digest. |
| `/agent source` | Select `builtin:jido` or one YAML or JSON agent file. The full remaining text is the source path. |
| `/model` | List selectable models, support tiers, and the current model. |
| `/model provider:model` | Select one exact model for the current live session. |
| `/execution-policy` | List registered policies and mark the current or requested policy. |
| `/execution-policy id` | Select one exact execution policy before the first prompt. |
| `/new-session` | From `resume_blocked`, create a clean thread without copying direct policy consent or prior work. |
| `/cancel` | Close a read-only blocked thread. |

Malformed or unknown slash commands show local feedback. They do not become
prompts. A command must use one line. Model selection accepts one exact
`provider:model` identity and no extra arguments.

`/agent` accepts the full trimmed remainder, so a file path can contain spaces.
`/execution-policy` accepts one ID and no extra arguments.

## Command Completion

Type `/` to show the available slash commands. Type a lower-case command prefix
to filter the list. Type `/model `, with a space, to show selectable models.
Text after that space filters the provider, model name, or full
`provider:model` identity. `/provider` is not a command.

Use these keys while suggestions are visible:

| Key | Result |
| --- | --- |
| `Up` | Move to the prior suggestion. |
| `Down` | Move to the next suggestion. |
| `Tab` | Put the selected command or model in the prompt. Do not run it. |
| `Enter` | Submit the prompt through the normal command path. |
| `Escape` | Close the suggestions and keep the prompt text. A later `Escape` uses the normal terminal behavior. |

The model list shows the support tier. It also marks the effective model as
`current`. The marker uses text, so it does not depend on terminal color.

Completion is local and advisory. It does not call a provider. It does not add
data to the transcript, prompt history, thread events, or model context. The
live session owner still validates the model, support tier, startup state, and
model lock after you press `Enter`. Thus, the owner can reject a model that was
in a local suggestion.

## Model Selection

Only models in the `supported` or `beta` tier are selectable. Models in the
`available` or `unsupported` tier are not selectable. `/model` sorts the list
by exact identity and marks the current model.

You can change the model until the first prompt is durably accepted. The model
then locks for that live session. A setup failure after prompt acceptance does
not unlock it. If durable prompt acceptance fails, the model stays selectable.

The selection is shared by all terminal clients that are attached to the same
live thread owner. It is part of the durable thread binding. A replacement
owner must rebuild the same model and origin before it opens resources.

Jido Console validates the identity and support tier from local catalog data.
This validation does not call a model provider and does not inspect provider
credentials. A `beta` selection is shown as beta in the terminal.

## Command Feedback

Command results and errors are local terminal notices. A complete session view
refresh does not remove recent notices. The notice list is bounded, and it is
not part of the model context, durable transcript, prompt queue, or event log.

## Agent Sources

The default source is the compiled `builtin:jido` agent. `--agent SOURCE`,
`:agent_source`, and `/agent SOURCE` also accept `.json`, `.yaml`, and `.yml`
Jidoka agent documents. Extension matching is case-insensitive. Console uses
the extension to select the parser. It does not inspect content to guess a
format.

One source can contain at most 1,000,000 bytes. The loader also limits decode
depth, node count, process memory, and elapsed time. It rejects symbolic links,
non-regular files, invalid UTF-8, duplicate keys, YAML anchors, aliases, merge
keys, and custom tags. It checks file identity before, during, and after the
read.

File agents can define allowlisted behavior data, such as instructions, model
defaults, generation settings, and an execution-policy request ID. They cannot
define tools, operations, extensions, registries, shared-memory routes, host
adapters, or consent. Coding tools come only from the host-selected coding
pack.

The loader uses a bounded pure-Elixir worker. OTP does not provide one portable
atomic open operation with every required no-follow and file-identity check.
The checks reduce same-host path races but cannot remove that residual limit.
Do not use an agent file in a directory that an untrusted same-host process can
change. This release keeps the loader in pure Elixir and does not add a native
file-opening helper.

## Execution Policies

The automatic default is `coding.restricted`. An agent document can request a
registered policy ID, but that request is not consent. The broader
`coding.trusted-workspace` policy needs an explicit CLI, API, or TUI choice and
an exact project root. It is not a sandbox.

The public Console term is **execution policy**. Console maps it to Jidoka's
existing `Jidoka.ExecutionEnvironment.SecurityProfile` and execution-
environment contracts. No Jidoka rename is required.

The owner locks the agent, model, coding pack, policy, and workspace evidence
with the first accepted prompt. Later selection commands show the locked value
and do not change it. A file digest, policy registration, model, or workspace
identity mismatch blocks exact resume before resources open.

## Deprecated Names

For the 0.1 release line, `--coding-profile`, `:coding_profile`,
`:coding_profile_resolver`, and `/profile` remain warning aliases. They
normalize to the canonical execution-policy data. Canonical and legacy names
in the same input layer are an error, even when their values match. Repeated
forms are also an error. The earliest planned removal is 0.2. Stored
`coding.local` values normalize to `coding.trusted-workspace` during the
compatibility window.
