# Durability and Recovery Backlog

## DURABLE-001: Separate local and portable audit chains

- Phase: 3
- Priority: medium
- Work: Keep a detailed local chain and a safe canonical export with an independent verifier.
- Acceptance: The portable verifier does not depend on OTP serialization or secret local data.

## DURABLE-002: Name recovery modes exactly

- Phase: 3
- Priority: high
- Work: Define deterministic replay, exact live resume, transcript-only resume, retry, and fork.
- Acceptance: Each operation states whether it can call a model or tool and whether it restores live state.

## DURABLE-003: Replay recorded sessions as regression tests

- Phase: 3
- Priority: high
- Work: Run current harness code against recorded model and tool results.
- Acceptance: The test reports prompt divergence, extra calls, unused calls, and event divergence.

## DURABLE-004: Keep canonical history immutable

- Phase: 3
- Priority: high
- Work: Build compact model context as a bounded supervised projection. Do not delete source history.
- Acceptance: Replay and fork use full history after prompt compaction. Compaction cannot block the session owner.

## DURABLE-005: Bind approval to exact resume data

- Phase: 3
- Priority: high
- Work: Store principal, role, client, origin, action, normalized parameter digest, policy rule, control, scope, decision, expiry, and pending request identity.
- Acceptance: Changed parameters, a different control, or an expired decision cannot resume the effect.

## DURABLE-006: Reserve external-effect results

- Phase: 3
- Priority: high
- Work: Store result identity, effective arguments, and replay policy before execution.
- Acceptance: Recovery can repeat a safe effect or record uncertain interruption for an unsafe effect without a duplicate result position.

## DURABLE-007: Accept commands and input atomically

- Phase: 3
- Priority: high
- Work: Store decided events, projections, input, and the idempotency receipt in one acceptance transaction. Publish or wake execution after commit.
- Acceptance: A retry cannot apply the same input or command two times. Events, projections, and receipts cannot show different committed states.

## DURABLE-008: Keep origin, trust, and accepted world state

- Phase: 3
- Priority: medium
- Work: Keep source trust on imported history. Separate proposed, verified, and accepted workspace consequences from the agent process.
- Acceptance: Imported data cannot silently become trusted. Agent exit does not remove accepted workspace state.

## DURABLE-009: Keep prompt-visible session shape stable

- Phase: 3
- Priority: medium
- Work: Freeze prompt-visible model, tool, skill, and memory shape for a session. Record an explicit immediate cache break.
- Acceptance: A normal configuration change starts in the next session. Replay shows when an immediate break occurred.

## DURABLE-010: Put the local session store under Jido home

- Phase: 3
- Priority: high
- Work: Open the indexed storage adapter under `state/` through the Jido home resolver. Define one writer, schema version, migration, backup, repair, retention, archive, removal, and explicit error behavior.
- Acceptance: Sessions survive restart. `JIDO_HOME` creates an isolated store. Not-found, storage error, and incompatible schema remain distinct and do not create a silent empty session.

## DURABLE-011: Add operating-system secret-store profiles

- Phase: 3
- Priority: medium
- Work: Add named profiles backed by the operating-system secret store. Store only provider, profile, and secret reference data. Use environment variables when no supported store is available.
- Acceptance: macOS Keychain, Linux Secret Service, and Windows Credential Manager adapters share one behavior. No Jido file or database contains plaintext credentials.

## DURABLE-012: Publish the Console-to-Jidoka durable coordinate

- Phase: 3
- Priority: high
- Work: Define one watermark with Console event sequence, Jidoka checkpoint or journal identity, session, turn, step, schema, and commit state.
- Acceptance: Exact resume can prove that both stores represent the same accepted execution boundary.

## DURABLE-013: Reconcile partial Console and Jidoka commits

- Phase: 3
- Priority: high
- Work: Define commit order, recovery, repair, and stop behavior for every crash point and both orphan-record directions. Put required additive changes in separate Jidoka and Console work.
- Acceptance: Crash injection loses no acknowledged event, repeats no unsafe effect, and produces no false exact-resume claim.

## DURABLE-014: Persist exact model invocation identity

- Phase: 3
- Priority: high
- Work: Persist provider, model, variant, generation settings, profile, prompt identity, tool schema, skill schema, fallback attempts, usage, and provider request identity for each durable turn.
- Acceptance: Replay and audit can state exactly which model contract and prompt-visible capability set produced each attempt without storing a credential.
