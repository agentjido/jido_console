# Clients and Protocol Backlog

## CLIENT-001: Build one client driver contract suite

- Phase: 2
- Priority: high
- Work: Define a small driver API for semantic input, output, snapshot, and control.
- Acceptance: TUI, automation, text, and JSON drivers pass the same behavior suite. Later clients must pass the same suite for their declared capabilities.

## CLIENT-002: Generate protocol types

- Phase: 2
- Priority: high
- Work: Define one canonical protocol schema and generate non-Elixir types and validators.
- Acceptance: CI fails when a generated type does not match the schema.

## CLIENT-003: Preserve bounded unknown wire data

- Phase: 2
- Priority: medium
- Work: Define an unknown-message envelope with raw type, bounded fields, and diagnostic data.
- Acceptance: A new message type does not stop the stream or gain authority. The adapter does not lose its bounded payload.

## CLIENT-004: Generate parity from client descriptors

- Phase: 2
- Priority: high
- Work: Declare input, streaming, approval, attachment, output, and fallback capabilities for each client surface.
- Acceptance: A parity check reports missing support and undeclared degradation.

## CLIENT-005: Tag operations with origin

- Phase: 2
- Priority: medium
- Work: Add source client and operation identity to semantic operations.
- Acceptance: Clients can prevent local echo and show provenance. Origin metadata cannot grant permission.

## CLIENT-006: Scope remote client access

- Phase: 8
- Priority: high
- Work: Exchange one-time bootstrap access for a scoped client session and a short-lived connection ticket.
- Acceptance: A pairing credential is not a normal session credential. Each client grant expires and can be revoked alone.

## CLIENT-007: Define collaborative synchronization

- Phase: 9
- Priority: high
- Work: Define initial snapshot, ordered operation, acknowledgement, revision report, presence, selection, gap, and reconnect messages.
- Acceptance: A late or reconnected client reaches current shared state. Transient presence data does not enter durable history.

## CLIENT-008: Constrain the local web client

- Phase: 5
- Priority: high
- Work: Bind the LiveView client to loopback and one local user. Keep draft, focus, selection, and viewport state local.
- Acceptance: A default start does not listen on a non-loopback interface. Terminal and web clients show the same session without shared drafts or a second owner.

## CLIENT-009: Add supported remote web and SSH transports

- Phase: 8
- Priority: high
- Work: Add authenticated remote web and SSH drivers with transport security, bounded input parsing, cancellation, resize, scrollback, resource limits, and audit.
- Acceptance: Both drivers pass the shared contract suite. SSH handles split key sequences, active-work Ctrl+C, normal text, resize, and disconnect without session corruption.

## CLIENT-010: Define multi-user identity and authorization

- Phase: 9
- Priority: high
- Work: Define user, organization, role, session, resource, client, and approval authority. Apply permissions before an operation enters session order.
- Acceptance: Transport or origin cannot grant authority. Revocation prevents later protected operations and does not invalidate unrelated grants.
