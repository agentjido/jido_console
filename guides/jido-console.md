# Jido Console Guide

Jido Console accepts normal prompts and a small set of slash commands in the
same input area. A slash command controls the local Console session. It is not
sent to the model and it is not saved in the conversation or thread history.

## Commands

Use `/help` to show the command list. Command names use lower-case text and do
not have aliases.

| Command | Result |
| --- | --- |
| `/help` | Show the command list. |
| `/model` | List selectable models, support tiers, and the current model. |
| `/model provider:model` | Select one exact model for the current live session. |
| `/profile` | Show the existing profile compatibility options. |
| `/profile profile` | Explain that profile changes require a new thread. |

Malformed or unknown slash commands show local feedback. They do not become
prompts. A command must use one line. Model selection accepts one exact
`provider:model` identity and no extra arguments.

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
live thread owner. A replacement owner starts with the model from its startup
configuration. The selection is not stored as a user preference and is not
restored from thread history.

Jido Console validates the identity and support tier from local catalog data.
This validation does not call a model provider and does not inspect provider
credentials. A `beta` selection is shown as beta in the terminal.

## Command Feedback

Command results and errors are local terminal notices. A complete session view
refresh does not remove recent notices. The notice list is bounded, and it is
not part of the model context, durable transcript, prompt queue, or event log.
