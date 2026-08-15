# First-user support boundary

Status: Accepted for Milestone 1 planning.

## User and job

- User: A software developer who can review a code change and its command output.
- Job: Install Jido Console on a supported local computer, select a tested model, complete one coding task, and review all file and process effects.
- Activation: The production artifact completes the frozen coding task in restricted mode. The exact diff, approval result, and test result are available for review.

## Initial support claim

| Boundary | Milestone 1 claim |
| --- | --- |
| Product | Local coding harness through the terminal and automation interfaces |
| Platform | macOS on Apple silicon |
| Channel | Direct archive, Homebrew, and npm packages that use the same native payload |
| Provider | OpenAI, Anthropic, and Google Gemini after their contract tests pass |
| Security | Restricted execution is the default; trusted-workspace mode is an explicit option and is not a sandbox |

## Non-claims

- No Linux or Windows support claim.
- No durable resume, multi-agent, remote executor, web, SSH, or multi-user support claim.
- No service-level, performance, cost, or provider-availability claim.
- No safety claim is valid until all Milestone 1 boundary tests pass on the released artifact.

The complete scope and exit conditions are in [Milestone 1](../01-ship-trustworthy-local-kernel/milestone.md). Beadwork item `jido_console-g0e09` owns changes to this decision.
