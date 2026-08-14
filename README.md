# Jido Console

> [!WARNING]
> Jido Console is in active development. It is not ready for use. There is no
> stable release, installation path, API, or data format yet.

## Help Build Jido Console

Start with the [roadmap](roadmap/README.md) and the
[contribution guide](CONTRIBUTING.md). The roadmap is open for review. Each
directory in `roadmap/milestones/` contains one milestone item.

### Major Roadmap Items

- [ ] [Establish repeatable release readiness](roadmap/milestones/00-establish-release-readiness/milestone.md).
- [ ] [Ship the trustworthy local multi-model kernel](roadmap/milestones/01-ship-trustworthy-local-kernel/milestone.md).
- [ ] [Ship the supervised semantic session plane](roadmap/milestones/02-ship-supervised-session-plane/milestone.md).
- [ ] [Add durable resume, fork, and audit](roadmap/milestones/03-add-durable-resume/milestone.md).
- [ ] [Add supervised multi-agent worktree lanes](roadmap/milestones/04-add-supervised-multi-agent-work/milestone.md).
- [ ] [Add the local LiveView workbench](roadmap/milestones/05-add-local-liveview-workbench/milestone.md).
- [ ] [Add isolated local executors](roadmap/milestones/06-add-isolated-local-executors/milestone.md).
- [ ] [Add managed and remote executors](roadmap/milestones/07-add-managed-and-remote-executors/milestone.md).
- [ ] [Add authenticated remote web and SSH access](roadmap/milestones/08-add-authenticated-remote-access/milestone.md).
- [ ] [Add multi-user collaboration](roadmap/milestones/09-add-multi-user-collaboration/milestone.md).
- [ ] [Add controlled live extension](roadmap/milestones/10-add-controlled-live-extension/milestone.md).

Read the [full roadmap](roadmap/README.md) for the order and architecture rules.

### Ways to Get Involved

- [Join the Jido Discord](https://jido.run/discord) to meet the community.
- [Start a Discussion](https://github.com/agentjido/jido_console/discussions/new/choose)
  to ask a question or propose an idea.
- Own a scoped implementation issue for a ready milestone. Read the
  [12-hour reservation policy](ROADMAP_OWNERSHIP.md) first.
- Give roadmap feedback in
  [Discussions](https://github.com/agentjido/jido_console/discussions).
- Test the current work and report failures in a
  [bug Discussion](https://github.com/agentjido/jido_console/discussions/new?category=q-a).

Jido Console collects no usage data or telemetry. A useful bug report includes
the operating system, architecture, OTP and Elixir versions, commit ID, exact
steps, expected result, actual result, and sanitized output. Add a small
reproduction when possible. Never include credentials.

## Jido, Jidoka, and Jido Console

| Project | Role |
| --- | --- |
| [Jido](https://github.com/agentjido/jido) | The Elixir framework and core building blocks for autonomous agents. |
| [Jidoka](https://github.com/agentjido/jidoka) | The runtime for agent sessions, execution, effects, cancellation, and recovery. |
| Jido Console | The user-facing control plane for terminal, automation, web, SSH, text, and JSON clients. |

Jidoka owns agent execution truth. Jido Console owns user-visible session truth.
A client presents session state. It does not own that state.

Jido Console is intended to run supported models, keep work alive, isolate
tools, show effects, compare results, and recover sessions without loss of
accepted work.

Licensed under Apache-2.0. See [LICENSE](LICENSE).
