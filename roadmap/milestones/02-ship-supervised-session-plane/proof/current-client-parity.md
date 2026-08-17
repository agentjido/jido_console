# Current Client Parity

This report records the M2-E31 provider-free parity proof.

## Corpus

- Schema: `jido.current-client-parity`
- Version: `1`
- Protocol version: `1`
- Source: `test/fixtures/session/current_client_parity_v1.json`
- Replay source: `priv/release/offline_fixture.json`
- Replay digest: `sha256:cace48232cdf26c6b325a45a1a0074cf1994e719b09eca534e29f2c7793636b8`
- Normalized ledger fingerprint: `sha256:075e0de8df90d5e56790a2b70e0a09099f142d07a2f3a6cd367cb9803f1252d8`

The corpus has fixed prompt, model content, tool identity, tool operation, source
request identity, session identity, and replay digest. The normalizer replaces
only generated client, attachment, Console request, Console run, and canonical
event identities. It keeps sequence, type, protocol, source identity, trust,
classification, semantic payload, and outcome data.

## Production paths

| Client | Production path | Semantic result |
| --- | --- | --- |
| TUI | `Jido.Console.Tui.run`, deterministic terminal, bounded TUI client batches | Match |
| Automation | `Jido.Console.run` for `run` and `eval`, Jidoka replay engine | Match |
| Text | Bounded `Session.Client.output` and public text projection | Match |
| JSON | Bounded `Session.Client.output` and public JSON projection | Match |

The TUI, automation adapter, text adapter, and JSON adapter produce the same
normalized live-output ledger. The proof does not use a direct session snapshot
or an observation helper as its oracle.

## Ordered outcome ledger

| Sequence | Type | Stable semantic data |
| --- | --- | --- |
| 1 | `run_started` | Session, request, run, and source request identities |
| 2 | `tool_started` | Step `parity-tool-v1`, operation `fixture.echo` |
| 3 | `tool_completed` | The same step and bounded completion content |
| 4 | `model_delta` | Text `OFFLINE` |
| 5 | `permission_requested` | Approval `parity-approval-v1` for `fixture.echo` |
| 6 | `permission_decided` | The same approval identity and decision `approved` |
| 7 | `run_completed` | One terminal outcome with content `OFFLINE` |

The common side-effect ledger is:

- Tool operation: `fixture.echo`
- Permission decision: `approved`
- Terminal type: `run_completed`
- Visible content: `OFFLINE`

## Lifecycle and recovery

All four attachment paths return the same results:

- Bounded queue overflow returns `delivery.gap`.
- Recovery returns `recovery_snapshot` and `recovery_suffix`.
- A stale completion token returns `stale_completion_token`.
- The exact completion token returns `recovery_receipt`.
- A detached handle returns `not_attached`.

All four paths also produce the same cancellation control transcript:

- `run_started`
- `control_requested`
- `control_completed` with status `ok`
- `run_failed` with reason `cancelled`

## Automation compatibility

Both public automation paths return success with the pinned replay. No live
provider or live execution environment is called.

- Record schema: `jido.case-result`, version `1`
- Execution status: `ok`
- Evaluation status: `passed`
- Replay status: `matched`
- Artifacts: `manifest.json`, `results.jsonl`, `summary.json`,
  `lifecycle.json`, and the per-agent JSONL file

## Boundary checks

The source guard scans the production TUI, automation, text, and JSON client
entries. It rejects raw Jidoka receive tuples, raw session runtime messages,
raw session control results, and direct session-server access. A second guard
rejects snapshot or observation-helper use in the parity oracle. A deliberate
raw-path fixture proves that the guard fails closed.

## Reproduction

Run:

```text
mix test test/jido_console/session/parity_test.exs \
  test/jido_console/session/parity_boundary_test.exs
```

Expected result: 8 tests pass with no live provider access.
