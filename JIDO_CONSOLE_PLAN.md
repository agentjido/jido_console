# Jido Console Architecture Plan

Status: **proposed target architecture**

Date: **2026-08-25**

This document defines the target architecture, product boundaries, public
surfaces, and main terms for Jido Console. It is the main architecture plan for
the application.

The canonical [roadmap](roadmap/README.md) owns delivery order, milestone
scope, and release gates. This plan owns the target shape. When the roadmap and
this plan disagree, maintainers must record one explicit architecture decision
and update both documents as needed.

## 1. Product Decision

Jido Console is a local-first, embeddable OTP control plane for Jidoka agent
sessions.

It adds the product services that a complete coding console needs:

- Durable, addressable sessions.
- Multiple clients for one session.
- Input admission, command handling, queueing, and review.
- Agent selection and session binding.
- Child-agent supervision and parallel work lanes.
- Storage selection and recovery.
- Execution selection, workspace control, and evidence.
- Safe views and renderer-neutral output.

Jidoka remains the only agent runtime. Jido Console does not copy the Jidoka
turn engine, tool loop, request controller, journal, or snapshot model.

The programmatic Elixir interface is a primary product surface. The terminal,
JSON client, automation client, future LiveView workbench, and future remote
clients are adapters over the same session contract.

This is not a terminal application with an internal API. It is an OTP
application with several clients, one of which is a terminal.

## 2. Main Architecture Rules

These rules control the design:

1. **Use Jido ecosystem terms.** Use `session`, not `thread`. Use `turn` for
   one user turn. Use `operation` for one model-callable unit.
2. **Keep one execution engine.** Jidoka owns agent execution and durable
   execution state.
3. **Make the Elixir API complete.** A host application must not need CLI,
   terminal, or JSON code.
4. **Keep clients replaceable.** A client translates input and renders output.
   It does not own session life.
5. **Give each live session one owner.** One supervised Console process admits
   commands and orders Console state changes for a session.
6. **Put child work under its session.** A child agent, lane, task, attempt,
   budget, and acquired execution resource must have a Console session ID.
7. **Use adapters at external boundaries.** Storage and execution have explicit
   contracts. Product code does not call a specific adapter directly.
8. **Persist portable data only.** Do not persist PIDs, references, functions,
   provider clients, credentials, or live execution handles.
9. **Report real authority.** An execution adapter must report its actual
   isolation and capabilities. It must not present a host process as a sandbox.
10. **Fail closed.** Do not silently replace a requested storage, policy,
    isolation level, workspace mode, or executor with a weaker choice.
11. **Use safe defaults.** A useful local configuration must work without a
    large host configuration. More authority always needs an explicit choice.
12. **Keep the first implementation small.** Add a concept only when it has one
    clear owner, identity, and lifecycle.

## 3. System Ownership

| Layer | Owns | Does not own |
| --- | --- | --- |
| Jido | Agent behavior model, Actions, Signals, Directives, and process-hosting patterns | Console sessions, client delivery, or execution-provider selection |
| Jidoka | Agent specifications, turns, requests, operations, reviews, results, journals, snapshots, handoffs, and bounded subagent calls | Console clients, product history, work-lane custody, or presentation |
| Jido Console | Session identity, command admission, client attachment, safe views, product history, bindings, orchestration records, recovery coordination, and adapter selection | A second agent loop or a copy of Jidoka execution state |
| Storage adapter | Durable Console records and a conforming Jidoka session store | Product policy or client rendering |
| Execution adapter | Workspace and execution resource operations inside declared capabilities | Agent behavior, Console authorization, or session identity |
| Host application | Authentication, authorization, tenants, routes, web sessions, and application records | Jidoka internals or Console session mutation rules |
| Client adapter | Input translation, local interaction, and rendering | Durable truth or session life |

## 4. Canonical Vocabulary

The following terms are the public product language.

| Term | Meaning |
| --- | --- |
| **Console instance** | One configured and supervised Jido Console runtime in an OTP node. The first supported form is one default instance. |
| **Session** | The durable user-facing unit of work. It contains a root agent, conversation, commands, clients, child-agent tree, execution bindings, and product history. |
| **Session reference** | A portable reference to a Console instance and session. It contains no process identity. |
| **Client** | A terminal, JSON process, Phoenix process, automation process, or other consumer of the programmatic contract. |
| **Attachment** | One monitored client connection to one session generation. A client can detach without stopping the session. |
| **Command** | A typed request to change Console session state or control work. |
| **Query** | A read-only request for a view, history page, catalog, capability report, or status. |
| **Receipt** | Durable evidence that Console admitted or rejected a command. |
| **Outcome** | The final Console result of an admitted command or task. |
| **Input** | User content that can start a Jidoka turn. Input is one command payload, not the turn itself. |
| **Turn** | One Jidoka user turn, from accepted input through final result, failure, or interruption. |
| **Request** | One durable Jidoka request inside a turn. |
| **Operation** | One normalized model-callable unit, such as a tool, MCP operation, browser operation, workflow, or bounded subagent call. |
| **Agent** | An author-facing behavior definition. It is not a process. |
| **Agent specification** | The resolved immutable Jidoka agent definition. |
| **Agent instance** | One logical root or child agent inside a Console session. It has its own identity and Jidoka session identity. |
| **AgentServer** | A Jido process that hosts an agent. Use this term only when the architecture uses that Jido process form. |
| **Subagent** | A bounded Jidoka delegation inside the current parent turn. The result returns to the parent. |
| **Child agent** | A durable Console-supervised agent instance under a parent agent in the same Console session. It can own a lane and run beyond one parent operation. |
| **Handoff** | A durable Jidoka routing change for future turns. It changes active ownership; it does not create a new Console session. |
| **Lane** | A session-scoped unit for isolated or parallel child work. It can own a workspace, task queue, budget, and custody state. |
| **Task** | A requested unit of child-agent work. |
| **Attempt** | One execution of a task. A retry creates a new attempt, not a new task. |
| **Binding** | Portable evidence of an exact resolved choice, such as an agent, model, coding pack, policy, or execution environment. |
| **Workspace** | The named file and project context available to a session or lane. |
| **Execution environment** | A policy-selected place and capability set in which file or process effects run. |
| **Execution handle** | A private, transient adapter value for an open or acquired environment. It is never a Console session. |
| **Artifact** | A portable result file or data object that can outlive one execution handle. |
| **View** | A safe current projection for clients. It is derived state, not an authority. |
| **Event** | A durable Console product fact that Jidoka does not already own. |

### 4.1 Replace `thread` with `session`

The target public API and documentation use `session_id`.

Current code and the experimental JSON version 1 protocol use names such as
`thread_id`, `Session.Thread`, and `thread_events`. These names are migration
inputs, not target vocabulary.

The migration must be explicit:

- New Elixir APIs use `session_id` from their first release.
- A new JSON protocol version uses `session_id`.
- JSON version 1 can keep `thread_id` for its documented experimental life.
- Internal modules move from `Session.Thread` to `Session.State` or another
  session term when the owner-state work lands.
- Physical SQLite table names can change in a storage migration. Product code
  must not expose those table names.
- Do not use both terms as equal public synonyms after the migration period.

## 5. System Shape

```text
Elixir host API    Terminal    JSON    Automation    LiveView    Remote later
       \              |         |          |            |            /
        +-------------+---------+----------+------------+-----------+
                                      |
                      Jido.Console public facade
                                      |
                 renderer-neutral session client contract
                                      |
                         Console session control plane
                    /          |             |          \
            Jidoka runtime   Storage     Orchestration  Execution
              and Jido       adapter        records      boundary
              concepts          |                         |
                            SQLite by              local filesystem,
                             default               sandbox, remote
```

Every product surface crosses the same Console boundary. A client cannot call
a session owner, a Jidoka request controller, a store writer, or an execution
provider directly.

## 6. Programmatic Interface

The programmatic interface is a supported local client surface. It must be
usable from Phoenix, a background worker, a test, an umbrella application, or
another OTP application.

### 6.1 Runtime integration

The target supports a named Console instance as an OTP child:

```elixir
children = [
  {Jido.Console.Instance,
   name: MyApp.Console,
   storage: [adapter: Jido.Console.Storage.SQLite],
   defaults: [execution_policy: "restricted"]}
]
```

The `jido_console` application can start one default instance for CLI use. An
embedded host can start a named instance and pass it to the facade. The first
implementation can support only one instance in one BEAM node, but public
references must not depend on a hard-coded registered name.

Infrastructure configuration belongs to the Console instance. Session binding
choices belong to a session. Do not mix the two option families.

### 6.2 Public facade

`Jido.Console` is the main facade. Lower modules can define data structures and
advanced operations, but an ordinary host must not call a server process.

Target use:

```elixir
{:ok, session_ref} =
  Jido.Console.start_session(
    [agent: "builtin:jido", workspace: project_root],
    server: MyApp.Console
  )

{:ok, %{client: client, view: view}} =
  Jido.Console.attach(session_ref, delivery: self())

{:ok, receipt} =
  Jido.Console.submit(client, "Run the tests", command_id: stable_id)

{:ok, view} = Jido.Console.status(client)
{:ok, page} = Jido.Console.history(client, limit: 100)

{:ok, receipt} = Jido.Console.cancel(client, request_id)

{:ok, child_receipt} =
  Jido.Console.start_child(client,
    task: "Review the storage boundary",
    workspace_mode: :isolated_copy
  )

{:ok, agent_tree} = Jido.Console.list_agents(client)
:ok = Jido.Console.detach(client)
```

The full facade must cover:

- Start, load, list, fork, close, and inspect sessions.
- Attach, reattach, detach, and subscribe clients.
- Submit, queue, steer, remove, cancel, approve, and deny.
- Select agent, model, coding pack, execution policy, executor, and workspace
  before the applicable lock point.
- Start, inspect, cancel, and collect child-agent work.
- Read views, history, receipts, outcomes, catalogs, and capabilities.
- Checkpoint, restore, or export only when the selected adapters support it.

### 6.3 Public interface rules

The public interface must:

- Never halt the BEAM VM.
- Never write terminal output.
- Never read terminal input.
- Return typed success and error values.
- Use opaque client handles and portable session references.
- Reject a stale, cross-instance, or cross-session handle.
- Keep raw Jidoka runtime events and internal processes private.
- Keep credential values and provider clients private.
- Document sync and async completion for every operation.
- Use the same admission and validation path as all other clients.

### 6.4 Phoenix boundary

A Phoenix application is a host and client adapter. It is not a second agent
runtime.

A LiveView or Channel process does this:

1. The host authenticates the user.
2. The host authorizes access to the application session.
3. The process attaches through `Jido.Console`.
4. It stores the opaque client handle in server-side state.
5. It translates browser input to typed Console calls.
6. It translates Console messages and views to browser data.
7. It detaches when the process stops.

Core Jido Console does not depend on Phoenix, Phoenix PubSub, Ecto, or a web
transport.

## 7. Sessions

A Console session is the main user-facing root. It survives one client, one
turn, and one transient execution handle.

### 7.1 Session identity

Use these identities:

```text
console_instance_id
  `-- session_id
      |-- root agent_instance_id -> root jidoka_session_id
      `-- child agent_instance_id -> child jidoka_session_id
```

The root Jidoka session ID can equal the Console session ID. A child agent has
a distinct Jidoka session ID so that its durable turn state is not mixed with
the root conversation.

The Console store records all relationships. A child Jidoka session is not a
new Console session.

### 7.2 Session manifest

The durable session manifest contains portable facts:

```text
Session.Manifest
  id
  console_instance_id
  generation
  status
  root_agent_instance_id
  active_agent_instance_id
  binding_manifest
  workspace_ref
  created_at
  updated_at
  closed_at
```

The binding manifest records exact identities, versions, and digests for:

- Agent source and resolved Jidoka agent specification.
- Model and provider contract.
- Coding pack and tool catalog.
- Execution policy and selected execution profile.
- Workspace identity and project-instruction digest.
- Extension set when extensions affect behavior.

It must not contain a live handle, PID, function, credential, provider client,
or provider-owned session object.

### 7.3 Session lifecycle

Use a small public lifecycle:

```text
starting -> idle <-> running
                  -> waiting_review
                  -> blocked
                  -> recovering
                  -> closed
```

An internal state can be more detailed. A client must not depend on internal
state-machine labels.

- `idle`: the owner is ready and has no active root turn.
- `running`: a root turn or child work is active.
- `waiting_review`: work needs a policy or user decision.
- `blocked`: a durable mismatch or unavailable required dependency prevents
  safe progress.
- `recovering`: the owner is proving durable state after restart.
- `closed`: no new commands are admitted.

Child work can continue when the root turn becomes idle if the task contract
allows it. The session view must show this state clearly.

### 7.4 Live owner state

One `Session.Server` owns command admission and current projection for one live
session generation.

Its private state owns:

- Validated runtime and storage references.
- Current Jidoka root session data.
- Session manifest and recovery status.
- Active and queued input.
- Active Jidoka request handle.
- Partial output and pending review.
- Client attachments and delivery state.
- Child-agent and lane summaries.
- Private acquired resource handles.
- View revision and safe error state.

This state must use a private struct. It is not a durable record or public API.

### 7.5 Session locks

Some choices lock when the first input is durably admitted. These include the
agent specification, model contract, coding pack, execution policy, and root
workspace identity unless an explicit migration contract says otherwise.

On resume, an explicit choice is an assertion against the stored binding. It
does not replace the stored binding. A mismatch blocks before any external
resource opens.

## 8. Commands, Queries, Receipts, and Outcomes

Keep mutation and observation separate.

### 8.1 Command envelope

Every mutation uses one transport-neutral envelope:

```text
Session.Command
  command_id       stable idempotency identity
  session_id
  client_id
  expected_generation
  type
  payload
  submitted_at
  correlation
```

The host or client supplies a stable `command_id` when retry is possible. The
same identity and same payload return the same admission result. The same
identity and different payload return a conflict.

### 8.2 Command groups

| Group | Examples |
| --- | --- |
| Input | `submit`, `steer`, `remove_queued` |
| Turn control | `cancel`, `pause`, `resume` when supported |
| Review | `approve`, `deny` |
| Binding | `select_agent`, `select_model`, `select_pack`, `select_policy`, `select_workspace` |
| Session | `close`, `fork`, `checkpoint`, `restore` |
| Orchestration | `start_child`, `cancel_child`, `retry_task`, `accept_lane`, `reject_lane` |

Queries such as `status`, `history`, `list_sessions`, and `capabilities` do not
use mutation receipts. They return a view or page with a revision and durable
watermark.

### 8.3 Admission flow

```text
client command
  -> validate handle, generation, type, and authority
  -> resolve idempotency identity
  -> persist receipt and required Console facts
  -> reply accepted or rejected
  -> start or queue asynchronous work
  -> publish progress
  -> persist and publish final outcome
```

An accepted reply means the selected store has durably recorded the required
admission state. It does not mean that the turn or child task has completed.

The receipt contains the command identity, admission status, durable sequence,
and related task or request identity when known.

### 8.4 Input, turn, request, and operation

Do not use these terms as synonyms:

```text
submit command
  `-- input
      `-- Jidoka turn
          |-- one or more Jidoka requests
          `-- zero or more operations per request
```

This distinction gives retries and recovery a clear boundary. A command retry
does not create a second turn. An operation retry does not create a second
input.

## 9. Events, Views, and Client Delivery

### 9.1 Event ownership

Store only Console product facts in `Jido.Console.Session.Event`.

Examples include:

- Command admitted or rejected.
- Input queued, started, removed, or interrupted.
- Client-neutral review presented or decided.
- Child agent requested, started, completed, failed, or cancelled.
- Lane created, custody changed, accepted, rejected, or merged.
- Execution binding selected, acquired, released, or blocked.
- Session recovered, blocked, forked, or closed.

Console events can refer to Jidoka turn, request, operation, journal, and
revision identities. They do not copy Jidoka execution transitions, snapshots,
leases, provider journals, or complete request results.

### 9.2 View

`Jido.Console.Session.View` is the safe current projection. It contains:

- Session identity, generation, lifecycle, and binding summary.
- Root and active agent identities.
- Transcript projection.
- Active request and partial output.
- Queued input.
- Pending reviews.
- Child-agent tree and lane summaries.
- Workspace, execution, and resource status.
- Safe errors and recovery state.
- View revision and durable watermark.

The view must not contain credentials, provider clients, raw adapter handles,
internal PIDs, or unrestricted exception data.

### 9.3 Delivery contract

The client contract needs:

- An attach snapshot.
- Ordered changes after that snapshot.
- Bounded buffering.
- Acknowledgement or an equivalent delivery watermark.
- Gap detection and snapshot refresh.
- A clear slow-client policy.
- Reattach with a known revision.
- Semantic messages that do not contain renderer instructions.

A terminal renderer, JSON encoder, and LiveView renderer can produce different
output from the same semantic message.

No attached client owns session life. A client exit removes only that
attachment. Active work can continue with zero clients.

## 10. Agent and Orchestration Model

One Console session contains one root agent instance and zero or more child
agent instances.

```text
Console Session S1
|
`-- Root Agent A0            Jidoka Session JS0
    |-- bounded subagent     nested in one A0 turn
    |-- Child Agent A1       Jidoka Session JS1, Lane L1
    |   `-- Child Agent A3   Jidoka Session JS3, Lane L3
    `-- Child Agent A2       Jidoka Session JS2, Lane L2
```

Every node remains tied to `S1`. A client can inspect and control the complete
tree through the session owner.

### 10.1 Bounded Jidoka subagents

A Jidoka subagent is one operation inside the parent turn.

- The parent keeps conversation ownership.
- The child receives an explicit task and bounded context.
- The child receives an explicit budget and authority subset.
- The result or continuation returns to the parent operation.
- Hibernation state nests in the parent Jidoka snapshot.
- It does not create a new Console session.
- It does not create a durable Console child-agent record by default.

Console records correlation and safe progress when a client needs to observe
the operation. Jidoka still owns the operation state.

### 10.2 Durable Console child agents

A Console child agent is for supervised work that needs an independent
lifecycle, durable progress, parallel execution, or a separate workspace lane.

The main record is:

```text
Session.AgentInstance
  id
  session_id
  parent_agent_instance_id
  kind                    root | child
  agent_spec_ref
  jidoka_session_id
  lane_id
  task_id
  status
  authority
  budget
  generation
  created_at
  completed_at
```

The record is portable. Process identity and acquired execution handles stay in
the live owner tree.

Child-agent lifecycle:

```text
requested -> admitted -> starting -> running
                                  -> waiting_review
                                  -> completed
                                  -> failed
                                  -> cancelled
                                  -> abandoned
```

A child result returns to the parent as a typed task outcome. The parent can
accept it, reject it, request a retry, or use it as input. Product policy must
state whether completion can change a shared workspace automatically.

### 10.3 Handoffs

A handoff changes who owns future turns inside the same Console session.

- Jidoka owns handoff validation and routing data.
- Console persists the active-agent projection and product history.
- A handoff can route to an existing session agent instance or create one
  through an admitted Console command.
- A handoff does not create a new root Console session.
- A handoff does not grant more authority than the session already has.

### 10.4 Lanes

A lane is the work boundary for a durable child agent or parallel task:

```text
Session.Lane
  id
  session_id
  agent_instance_id
  task_id
  workspace_ref
  execution_binding_ref
  custody
  status
  budget
  created_at
  closed_at
```

Lane custody states can include `agent`, `parent`, `user_review`, and `closed`.
Custody states describe who can make the next mutation. They do not replace
host authorization.

For coding work, a lane can use an isolated copy or worktree. A completed lane
does not silently merge into the root workspace. Accept, reject, and merge are
explicit session commands with evidence.

### 10.5 Tasks and attempts

A task has one stable goal. Each execution or retry is an attempt.

- A retry keeps the task ID and creates a new attempt ID.
- An attempt records its parent, selected agent, workspace, execution binding,
  budget use, result, and error class.
- A completed task has one accepted outcome even if it has several attempts.
- A child agent can process one task at a time in the first implementation.

### 10.6 Budget and authority inheritance

A child receives the intersection of:

```text
host authorization
AND Console session policy
AND parent remaining authority
AND agent declaration
AND selected execution capabilities
```

The result can only remove authority. It cannot add authority.

Budgets can cover:

- Child depth and concurrent child count.
- Turns and model requests.
- Tokens and cost.
- Wall time and idle time.
- Operation count.
- Workspace bytes or changed files.
- Execution leases and process count.

The first delivery can support a small subset, but the record must allow a
bounded child depth and child count from the start.

### 10.7 Cancellation and failure

Cancellation follows the session tree:

- Cancelling a bounded subagent follows Jidoka operation rules.
- Cancelling a child agent cancels its active Jidoka request and its owned
  descendant work.
- Cancelling a parent can cancel, detach, or preserve a child only when the
  task contract states that choice.
- Closing a session cancels or safely abandons all remaining child work.
- An owner crash must not leave an untracked process or execution lease.

The default is recursive cancellation. Detached child work needs an explicit
policy and remains tied to the same Console session until completion.

## 11. Storage Architecture

Storage is an adapter boundary. SQLite is the default adapter, not part of the
generic product contract.

### 11.1 Two authorities, one configured boundary

Jidoka and Console keep separate data ownership:

```text
Storage Adapter
|-- Jidoka.Session.Store
|   `-- sessions, requests, snapshots, leases, journals, results
`-- Console product store
    `-- session catalog, receipts, events, bindings, delivery watermarks,
        agent tree, lanes, tasks, attempts, execution evidence
```

The configured Console storage adapter provides a public
`Jidoka.Session.Store` reference and Console operations. This lets one adapter
use one transactional database when that is possible.

Console must not write Jidoka-owned data through private Jidoka modules. Jidoka
must not write Console product records.

### 11.2 Adapter contract

`Jido.Console.Storage.Adapter` must cover:

- Start, health, migration, and shutdown.
- Access to a conforming public `Jidoka.Session.Store`.
- Session manifest create, read, list, update, fork, and close.
- Atomic command admission and idempotency conflict checks.
- Ordered Console event append and bounded reads.
- Binding manifest lock and comparison.
- Agent-instance, lane, task, attempt, and budget records.
- Execution binding, checkpoint, and evidence records.
- Open-work and recovery queries.
- Durable watermark and uncertain-write results.

The exact callback list can grow by capability family. Generic Console modules
must dispatch every storage operation through the selected adapter. They must
not call `Jido.Console.Storage.SQLite` directly.

### 11.3 Required semantics

Every complete adapter must preserve:

- Sync-before-reply for durable command admission.
- Idempotent identity and payload conflict detection.
- Required atomic binding and first-input admission.
- Ordered event sequences within one Console session.
- Compare-and-set or lease semantics for one live owner generation.
- Bounded, stable history pages.
- Exact recovery watermarks between Console and Jidoka facts.
- Explicit `unavailable`, `conflict`, and `uncertain_write` results.
- Migrations that do not expose partial schema state.

If an external database cannot make a Console write and Jidoka write atomic,
the adapter must use an explicit intent, watermark, and recovery protocol. It
must not report false success.

### 11.4 Adapter set

Plan for these adapters:

| Adapter | Use |
| --- | --- |
| SQLite | Safe local default and release storage |
| In-memory test adapter | Fast contract and failure tests; not a durable product mode |
| Ecto/PostgreSQL adapter later | Phoenix or service hosts that need a shared database |
| Host-defined adapter | A complete adapter that passes the same conformance suite |

The first supported product configuration uses one adapter per Console
instance. Per-session storage selection and cross-adapter session movement are
not initial requirements.

### 11.5 Storage conformance

Provide one adapter conformance suite. It must test:

- Durable admission and duplicate retry.
- Same identity with a different payload.
- Binding lock races.
- Owner-generation fencing.
- Ordered append and bounded pagination.
- Crash before, during, and after commit.
- Recovery of open turns and child work.
- Jidoka store behavior.
- Migration and version mismatch.
- No adapter bypass from generic Console code.

## 12. Execution Boundary

Jido Console must use the public Jidoka execution-environment boundary. It must
not build a second effect runtime.

The current Jidoka contracts already provide the correct main concepts:

| Jidoka contract | Use in Jido Console |
| --- | --- |
| `ExecutionEnvironment.SecurityProfile` | Required isolation, network, workspace mode, limits, image, checkpoint, fork, and retention |
| `ExecutionEnvironment.AdapterCapabilities` | Honest statement of what one adapter can enforce |
| `ExecutionEnvironment.PolicyRequest` | Policy input for environment selection |
| `ExecutionEnvironment.Selection` | Exact selected adapter and profile evidence |
| `ExecutionEnvironment.Binding` | Portable durable environment identity |
| `ExecutionEnvironment.Adapter` | Open, acquire, checkpoint, restore, fork, close, cleanup, and optional execute boundary |
| `ExecutionEnvironment.Manager` | Private handle ownership and exclusive acquisition |

Console `ExecutionPolicy` is the product selection and user-facing policy
layer. It resolves to Jidoka security profiles and policy requests. Console
does not give a provider-owned object to clients.

### 12.1 Execution concepts

Keep these concepts separate:

- **Policy:** what authority and isolation are required.
- **Profile:** one exact, named set of requirements and limits.
- **Capabilities:** what an adapter can truly enforce.
- **Selection:** why one adapter and profile matched the request.
- **Binding:** portable durable environment identity.
- **Handle:** private open provider resource.
- **Workspace:** files and project context presented to the environment.
- **Execution request:** one typed file, process, service, or control action.
- **Execution result:** one portable result with output, status, timing, and
  evidence.
- **Checkpoint:** an adapter-owned restore point with a portable reference.
- **Artifact:** a result that can be read after the handle closes.

An execution provider can use the word `session` in its own API. Console must
keep that object behind the adapter and call it a handle or environment in
Console code. A provider session is not a Console session and not a Jidoka
conversation session.

### 12.2 Adapter families

Plan for these implementations:

| Family | Intended use | Security statement |
| --- | --- | --- |
| Local filesystem | Read or change an explicitly selected host workspace | Trusted host access; not a sandbox |
| Local process | Run bounded commands in an explicitly selected host workspace | OS process boundary only; not a strong security boundary |
| Sandbox adapter | Restricted file and process work with copy-in or isolated storage | Isolation depends on the selected backend and declared capabilities |
| Container or microVM | Stronger local isolation and repeatable images | Must report actual container, VM, or microVM guarantees |
| Remote executor | Policy-approved work on another host | Requires identity, transport, lease, evidence, and failure contracts |

There is no silent fallback from sandbox, container, microVM, or remote
execution to a local host process.

### 12.3 Local filesystem adapter

Local filesystem support is required. It is the simple local development path.

The adapter must:

- Receive one canonical workspace root.
- Reject path escape after canonical path and symlink checks.
- Declare read-only or read-write access explicitly.
- Keep shell and network capabilities separate from file capabilities.
- Return portable file metadata and content results.
- Apply bounded read, write, search, and listing limits.
- Record mutation evidence for review and recovery.
- Support explicit cleanup for temporary files that it owns.
- State clearly that host filesystem access is not a sandbox.

Useful initial profiles are:

- `local.read_only`: project reads and searches; no writes or process launch.
- `local.trusted_workspace`: bounded file changes and selected local process
  operations in a trusted workspace.
- `isolated.restricted`: copy-in file and process work through a qualified
  isolated adapter.

The default restricted execution policy can allow local read-only operations.
If one effect requires isolation, it must fail when no qualified isolated
adapter is available. It must not silently become `local.trusted_workspace`.

### 12.4 Litter Box reference

[Litter Box](https://github.com/zblanco/litter_box) is a useful design
reference and a possible execution adapter. Its
[architecture](https://github.com/zblanco/litter_box/blob/main/ARCHITECTURE.md)
separates profile, policy, workspace, capabilities, provider session, execution
request and result, and backend adapter.

Jido Console should use these parts of that design:

- Capability negotiation before resource open.
- Explicit workspace modes.
- Copy-in as the safer default for isolated work.
- Bind and write-back only by explicit policy.
- Separate one-shot execution, persistent workspace, process host, and service
  life levels.
- Honest isolation and limitation reports.
- Fail-closed selection when a backend cannot enforce the profile.
- Checkpoint, process, file, service, proxy, and lease contracts only when the
  selected adapter supports them.

A Litter Box adapter maps its provider contracts to the public Jidoka
`ExecutionEnvironment.Adapter`. Jido Console does not depend on Litter Box
types outside that adapter. This plan does not make Litter Box a required
dependency. Qualification, dependency review, and an adapter proof must occur
before adoption.

### 12.5 Workspace modes

Use a small portable set:

- `none`: no project files.
- `read_only`: project files are visible but cannot change.
- `isolated_copy`: explicit copy-in; changes stay isolated until accepted.
- `trusted_bind`: direct host workspace access after explicit trust.
- `persistent`: adapter-owned workspace that survives one handle.

An adapter can support fewer modes. Policy selection rejects an unsupported
mode.

### 12.6 Execution request and result

Console-facing execution requests must be typed and bounded. Initial families
can include:

- File read, list, search, stat, write, patch, and remove.
- Process start, await, input, signal, and stop.
- Checkpoint, restore, fork, and cleanup.
- Artifact put, list, and get.

Arbitrary provider calls do not cross the boundary.

Results must contain portable data:

- Request and correlation identities.
- Status and typed error class.
- Standard output and error with truncation metadata when applicable.
- Exit status or operation result.
- Start, end, and duration.
- Adapter, profile, binding, and capability evidence.
- File changes and artifact references.
- Resource-use data when available.

### 12.7 Resource ownership

An execution binding is durable. An acquired handle is transient.

- A session or lane owns the portable binding.
- A supervised resource owner holds the live handle.
- The Jidoka manager enforces exclusive acquisition when required.
- Owner generation fences stale processes.
- Cleanup is idempotent.
- A crash triggers release or later lease cleanup.
- Credentials are injected at the final host boundary and are not persisted in
  Console records.

## 13. Workspace and Coding Model

Keep these choices separate:

| Choice | Owns | Does not own |
| --- | --- | --- |
| Agent source | Agent behavior, instructions, and agent defaults | Tools or host authority |
| Coding pack | Coding operations and workspace context rules | Isolation or host permission |
| Execution policy | Authority, limits, isolation, network, and workspace mode | Agent behavior or tool definitions |
| Executor adapter | Mechanism that enforces supported parts of the policy | Product authorization |
| Workspace | Project identity, files, instructions, and mutation evidence | Agent behavior or credentials |

A workspace reference includes a canonical root or adapter identity, a project
instruction digest, and trust status. It does not need to contain all files.

Project instructions, file mentions, and repository context become bounded
Jidoka context input. They do not grant execution authority.

For changed files, Console must be able to show:

- Which session, lane, task, attempt, and operation made the change.
- Which workspace and execution binding were active.
- Whether the change is isolated, pending review, accepted, rejected, or
  merged.
- Which validation ran and its result.

## 14. Models, Providers, and Credentials

Model selection is part of the session binding.

- The packaged catalog supplies model facts such as limits and lifecycle.
- Console supplies the smaller support allowlist and known contract status.
- A catalog entry alone is not a support claim.
- A stored model identity must resolve to the same supported contract on
  resume, or the session blocks for an explicit migration.
- The first admitted input locks the effective model contract.

Credentials belong to the host boundary:

- Read credentials from approved host configuration or secret providers.
- Do not put credential values in bindings, events, views, snapshots, logs, or
  artifacts.
- Give child agents only the credential scopes that their operations require.
- A client can see credential readiness, never the secret value.

## 15. Extensions

Extensions can add actions, client commands, renderable semantic output,
context providers, or execution adapter integrations. They cannot bypass the
session owner, Jidoka, storage, policy, or execution boundaries.

An extension must declare:

- Stable identity and version.
- Added operation or command types.
- Required capabilities and policy.
- Public and private configuration.
- Durable data and migration needs.
- Safe client projection.
- Failure and cleanup behavior.

The first architecture does not need a general plugin marketplace. A small
compiled extension registry is sufficient.

## 16. OTP Process Architecture

### 16.1 Console instance tree

```text
Jido.Console.Instance.Supervisor                 rest_for_one
|-- Jido.Console.Process.Supervisor              host child-process cleanup
|-- Jido.Console.Storage.Supervisor
|   |-- optional local home lock
|   `-- selected storage owner
|-- Jido.Console.Execution.Supervisor
|   |-- profile and adapter registry
|   `-- Jidoka execution-environment managers
`-- Jido.Console.Session.Supervisor
    |-- session Registry
    `-- session DynamicSupervisor
        `-- Session.RuntimeSupervisor x N

Jidoka.Supervisor                                owned by Jidoka

Terminal, JSON, Phoenix, automation              clients outside session trees
```

Storage starts before session mutation. Execution registries start before a
session can acquire a resource. `rest_for_one` stops later mutation owners when
an earlier authority fails.

### 16.2 Per-session tree

Subagents and resources must be tied to a session in the process tree:

```text
Session.RuntimeSupervisor(session_id)            rest_for_one
|-- Session.Server                               one admission owner
|-- Session.TurnTaskSupervisor                   root turn workers
|-- Session.AgentSupervisor                      child-agent owners
|   `-- Session.AgentWorker x N
`-- Session.ResourceSupervisor                   acquired handles and processes
```

The exact child modules can change, but these ownership rules must not:

- One `Session.Server` owns admission and public state order.
- Blocking model, tool, file, and process work stays outside its callbacks.
- A child-agent worker has one parent agent identity and one session identity.
- A session-scoped supervisor owns temporary turn and child work.
- A resource process cannot outlive its session without an explicit durable
  lease and recovery policy.
- A restarted owner rebuilds from durable data before it admits new mutations.
- Jidoka owns its internal supervisors. Console uses only public Jidoka APIs.

### 16.3 Concurrency rules

The first complete architecture uses conservative limits:

- At most one active root turn in a session.
- A bounded number of active child agents per session.
- At most one active turn per child agent.
- A bounded global count for model requests and execution allocations.
- Per-session and per-lane queue limits.
- No unbounded task, mailbox, output, history, or child tree.

Parallel child work is explicit. It does not make root session mutation
concurrent. Child outcomes pass through the session owner before they change
the root projection or shared workspace custody.

## 17. Durability and Recovery

Recovery must reconcile two authorities without copying one into the other.

### 17.1 Durable records

Persist:

- Session manifest and binding manifest.
- Command receipts and Console product events.
- Agent instances, parent relations, lanes, tasks, attempts, and budgets.
- Portable Jidoka session data through the Jidoka store.
- Execution bindings, checkpoint references, leases, and evidence.
- Durable delivery or recovery watermarks when needed.

Do not persist:

- PIDs, monitors, references, functions, tasks, sockets, or ports.
- Provider clients or provider-owned open resource objects.
- Raw credentials.
- Derived views or unbounded partial output.

### 17.2 Restart flow

For one session:

1. Acquire or prove the next owner generation.
2. Read the Console manifest, open receipts, events, and orchestration records.
3. Read Jidoka session data through the public store.
4. Rebuild and compare the binding before external resource open.
5. Reconcile admitted commands with Jidoka requests by stable identity and
   watermark.
6. Restore or reacquire execution resources only when the profile allows it.
7. Mark uncertain child attempts or processes for explicit recovery.
8. Build a safe view.
9. Admit new commands only after proof completes.

Do not replay external work from an event list without idempotency evidence.
When the system cannot prove if a write or external effect completed, report an
uncertain state and require a policy decision.

### 17.3 Fork

A session fork creates a new Console session with a new root identity. It can
refer to a Jidoka snapshot and execution checkpoint that the selected adapters
support.

A child agent or lane is not a session fork. A provider environment fork is
not a session fork. These operations can be used as parts of the Console fork,
but the Console session manifest is the product authority.

## 18. Security and Trust

The main trust decision is a combination of independent choices:

```text
authenticated host identity
  + host authorization
  + agent source
  + coding pack
  + execution policy
  + executor capabilities
  + workspace trust
  + credential scope
```

Rules:

- Agent content cannot grant itself a broader policy.
- Coding tools do not imply permission to use them.
- A local filesystem adapter states that it has host access.
- A local process is not called a sandbox.
- Network access is explicit and separate from file access.
- Bind mount and write-back modes need explicit authorization.
- Child authority cannot exceed parent authority.
- Reviews are durable and bound to exact request and operation identities.
- Resume compares exact binding evidence before resource acquisition.
- Client-facing errors remove secrets, paths outside the allowed workspace,
  and unrestricted stack data.

## 19. Client Surfaces

All clients use the programmatic contract.

| Surface | Role |
| --- | --- |
| Elixir API | Primary supported embedding surface |
| Terminal UI | Interactive local client and renderer |
| JSONL | Experimental local protocol and session-boundary pressure test |
| Automation | Non-interactive local commands and typed exit results |
| LiveView | Supported local web workbench in its roadmap milestone |
| Remote protocol later | Authenticated adapter over the same command, query, and delivery semantics |

No surface gets a private mutation path. A surface can add local usability,
such as key bindings, browser presence, or JSON encoding, but it cannot change
session semantics.

## 20. Configuration and Safe Defaults

Configuration has three levels:

1. **Console instance configuration:** storage adapter, registries, limits,
   available execution adapters, delivery bounds, and defaults.
2. **Session binding request:** agent, model, coding pack, execution policy,
   workspace, and extensions.
3. **Command options:** stable identity, expected generation, target request,
   target agent, or target lane.

Do not let a command replace instance configuration.

Default behavior:

- One local Console instance.
- SQLite under `JIDO_HOME`.
- Built-in agent source.
- Supported default model policy.
- Bounded queues, child count, output, and history.
- Restricted execution policy.
- No network unless the effective profile permits it.
- No direct host write unless the user or host selects a trusted workspace
  profile.
- Local filesystem read support for an explicit workspace.
- No remote clients or remote executors by default.

The CLI and an embedded host use the same default resolver.

## 21. Target Module Boundaries

The target module map is a guide, not a demand for one large rename:

```text
Jido.Console                              public facade
Jido.Console.Instance                     named OTP runtime

Jido.Console.Session                      session operations and data
Jido.Console.Session.Ref
Jido.Console.Session.Manifest
Jido.Console.Session.Client
Jido.Console.Session.Command
Jido.Console.Session.Query
Jido.Console.Session.Receipt
Jido.Console.Session.Outcome
Jido.Console.Session.Event
Jido.Console.Session.View
Jido.Console.Session.State                private owner state
Jido.Console.Session.Server
Jido.Console.Session.RuntimeSupervisor

Jido.Console.Orchestration.AgentInstance
Jido.Console.Orchestration.Lane
Jido.Console.Orchestration.Task
Jido.Console.Orchestration.Attempt
Jido.Console.Orchestration.Budget

Jido.Console.Storage.Adapter
Jido.Console.Storage.SQLite
Jido.Console.Storage.Memory                test only

Jido.Console.Execution                    policy and selection facade
Jido.Console.Execution.LocalFilesystem
Jido.Console.Execution.LocalProcess
Jido.Console.Execution.LitterBox           possible adapter

Jido.Console.Workspace
Jido.Console.AgentSource
Jido.Console.ModelCatalog
Jido.Console.Client.*                      terminal, JSON, and later adapters
```

Use the existing public Jidoka modules for execution, agent specs, sessions,
turns, requests, operations, handoffs, and subagents. Do not create Console
copies with different semantics.

## 22. Delivery Sequence

Deliver this architecture through small roadmap-owned units.

### Phase A: vocabulary and public boundary

- Make this document the target architecture source.
- Change new public design language from thread to session.
- Define the complete `Jido.Console` facade and typed error families.
- Keep CLI startup, VM halt, parsing, and terminal IO outside the facade.
- Add one programmatic embedding guide and contract test.

Roadmap fit: supervised session plane and renderer-neutral client contract.

### Phase B: session data and delivery

- Add portable session reference, manifest, receipt, outcome, and query types.
- Replace the private untyped owner map with a private state struct.
- Complete attach snapshot, bounded delivery, acknowledgement, gaps, and
  reattach.
- Make terminal and JSON clients use the same facade.
- Introduce JSON protocol session terminology in a new protocol version.

Roadmap fit: multi-client session plane.

### Phase C: durable storage boundary

- Move all SQLite-specific calls behind `Storage.Adapter`.
- Add owner-generation fencing and durable command receipts.
- Add the storage conformance suite.
- Qualify SQLite and the in-memory test adapter.
- Prove exact Jidoka and Console recovery.

Roadmap fit: durable resume and storage qualification.

### Phase D: execution boundary

- Route policy selection through public Jidoka execution-environment contracts.
- Add local filesystem and local process profiles with honest capability
  reports.
- Persist portable selections, bindings, and evidence.
- Add session-scoped resource ownership and cleanup.
- Qualify one isolated adapter. Evaluate a Litter Box adapter against the same
  suite.

Roadmap fit: local coding first, isolated and remote execution later.

### Phase E: session-scoped agent orchestration

- Add durable root and child agent-instance records.
- Add lane, task, attempt, budget, custody, and cancellation rules.
- Add the per-session agent supervisor and bounded child concurrency.
- Expose child tree and progress in session views.
- Keep bounded Jidoka subagents distinct from durable Console child agents.
- Add isolated workspace accept, reject, and merge commands.

Roadmap fit: supervised multi-agent work.

### Phase F: additional clients

- Add the supported local LiveView workbench as a client adapter.
- Add extension points only after the core client and policy contracts settle.
- Add authenticated remote clients only after identity, delivery, and recovery
  contracts are proven locally.

Roadmap fit: local workbench, then extensions and remote operation.

## 23. Architecture Verification

Use recorded or injected Jidoka results for contract tests. Live model calls are
not required for architecture proof.

### 23.1 Programmatic surface

Prove that:

- An OTP host starts a Console instance without CLI code.
- The host starts or loads a session through `Jido.Console`.
- No programmatic call halts the VM or writes terminal output.
- Phoenix-like client processes can attach and detach with opaque handles.
- TUI and JSON use the same command admission and view logic.

### 23.2 Session and client behavior

Prove that:

- Two clients see one semantic session state.
- One client failure removes only its attachment.
- Work can continue with zero attached clients.
- Reattach detects gaps and receives a current snapshot.
- A stale generation cannot mutate the session.
- A duplicate command does not create a duplicate turn or child task.

### 23.3 Agent orchestration

Prove that:

- Every child agent has one parent and one Console session.
- Each durable child has a separate Jidoka session identity.
- A bounded Jidoka subagent does not create a second Console session.
- Child budgets and authority cannot exceed the parent.
- Root and child concurrency stay within limits.
- Recursive cancellation cleans child requests and resources.
- A completed lane cannot change the root workspace without the required
  custody transition.

### 23.4 Storage and recovery

Prove that:

- Every generic storage operation reaches the configured adapter.
- SQLite and the test adapter pass the same contract suite.
- Storage failure cannot produce false durable acknowledgement.
- Recovery does not run an external effect twice without idempotency proof.
- Binding mismatch blocks before model, filesystem, process, or remote resource
  open.

### 23.5 Execution

Prove that:

- The local filesystem adapter cannot escape its canonical root.
- Read-only and read-write profiles differ in enforced capability.
- Local process execution is not reported as sandbox isolation.
- Unsupported isolation or workspace mode fails closed.
- A provider session or handle never appears in a Console view or durable
  record.
- Session close cleans or durably tracks every acquired resource.

## 24. Initial Non-Goals

This plan does not require these items in the first complete programmatic
release:

- A distributed Console registry.
- Multi-node session ownership transfer.
- A remote public protocol.
- Per-session storage adapters.
- A general plugin marketplace.
- An unbounded autonomous child-agent swarm.
- Silent background merges into a user workspace.
- A replacement for Jidoka execution state.
- A Phoenix dependency in core Console code.
- A claim that local host execution is secure isolation.
- Adoption of Litter Box before adapter qualification.

## 25. Completion Definition

The architecture is in place when:

- `Jido.Console` is a complete, supported programmatic surface.
- CLI, TUI, JSON, tests, and embedded hosts use the same session contract.
- Public language and new protocols use `session`, not `thread`.
- Jidoka remains the only agent runtime and execution-state owner.
- One Console session can supervise a bounded tree of durable child agents.
- Bounded Jidoka subagents, durable child agents, and handoffs have distinct
  and documented semantics.
- SQLite can be replaced by one complete storage adapter without session-code
  changes.
- Local filesystem execution and isolated execution cross one public Jidoka
  environment boundary.
- Every execution profile reports real capabilities and fails closed.
- Safe defaults work with no large host configuration.
- Restart recovery has exact identity, binding, receipt, and resource evidence.
- No public or durable value contains a live process, credential, provider
  client, or raw execution handle.

At that point, Jido Console is a coherent application platform over Jidoka. It
is not only a terminal harness. It is a session, orchestration, storage, and
execution control plane that other local applications can embed safely.
