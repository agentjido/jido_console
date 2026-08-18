# Durable Records, Codecs, and Migrations

This guide describes the version 1 durable data contract and its default local
SQLite repository.

## Default SQLite Repository

`Jido.Console.Session.Store.SQLite` stores sessions in
`JIDO_HOME/state/sessions/v1/console.sqlite3`. When `JIDO_HOME` is not set, the
path starts at `~/.jido`. The repository uses Exqlite 0.39.0 directly under its
MIT license. It does not use Ecto, a host `sqlite3` program, or a database
service.

The repository verifies WAL mode, `synchronous=FULL`, 4,096-byte pages, foreign
keys, trusted-schema disablement, and its 1 GiB page ceiling each time it opens.
It keeps 160 MiB for control work and stops normal admission at 864 MiB. All
range reads require count and byte bounds. The file and its directories use
private modes.

The supervised quota owner measures every file below
`JIDO_HOME/state/sessions/v1` by the larger of logical size and allocated
blocks. Seven fixed budgets total 4 GiB: 1,024 MiB for the active database,
384 MiB for WAL, 16 MiB for control files, 1,024 MiB for backups, 512 MiB for
archives, 1,024 MiB for shared work, and 112 MiB for structural safety. Normal
work stops at 3.5 GiB. Only the closed control-operation set can use the last
512 MiB.

| Quota class | Hard bytes |
| --- | ---: |
| Active database | 1,073,741,824 |
| WAL | 402,653,184 |
| Control files | 16,777,216 |
| Verified backups | 1,073,741,824 |
| Verified archives | 536,870,912 |
| Shared staging, quarantine, repair, and temporary work | 1,073,741,824 |
| Structural safety | 117,440,512 |

The quota owner accepts control reservations only for cancellation, safe
completion, checkpoint finalization, recovery, bounded audit-export metadata,
confirmed session removal, confirmed whole-backup retirement, confirmed
whole-quarantine retirement, and shutdown. A confirmed removal or retirement
can add at most 1 MiB of database pages, 256 MiB of WAL, and 8 MiB of control
files. It must start below 64 MiB of measured WAL.

Each reservation has one operation identity and separate source and destination
high-water values. The owner serializes concurrent reservations, includes
measured free disk space, and writes a bounded private reservation journal
before work starts. It reconciles committed, rolled-back, cleaned-up, expired,
and restarted work against the current file tree while it keeps the same
operation identity. Application temporary work is limited to 16 MiB per file
and 64 MiB in total.

Console records and authoritative Jidoka values use different tables. Each
mutation commits its operation receipt in the same transaction. A caller can
look up that receipt after an unknown timeout result. Store inspection checks
SQLite integrity, metadata, pragmas, and every stored record digest.

## Durable Storage Owner

The application starts storage before session supervision with rest-for-one
ordering. The storage tree owns, in order, one home lock, one maintenance
manifest, one admission counter, and one SQLite writer. A lock or integrity
failure prevents the session tree from starting. A writer failure makes public
storage calls unavailable until its supervised restart finishes.

The public write path reserves copied bytes before it sends to the writer. It
has 112 normal slots, 16 control slots, one shared 16 MiB small-payload pool,
one 136 MiB normal large lane, and one 136 MiB control large lane. The SQLite
process serializes all work, so only one transaction or reader runs at a time.
This is stricter than the declared maximum reader pool and prevents a retained
reader from holding the WAL open.

SQLite waits at most 250 ms for a busy database. Public calls wait at most one
second. A mutation timeout returns `timeout_unknown` with its operation ID, and
the caller can query the receipt. WAL auto-checkpoint work starts at 64 MiB;
page-adding admission stops if a blocked WAL reaches 384 MiB.

Stopped-store maintenance first terminates the writer. It then writes one
canonical manifest of at most 64 KiB by syncing a private temporary file,
renaming it, and syncing the parent directory. Startup reconciles an incomplete
manifest before it opens SQLite again.

## Console Records

The durable catalog defines 16 authoritative Console record types. Each type
has one required field set, one allowed field set, and explicit field types.
Unknown fields fail. One encoded Console record is at most 256 KiB.

Each record envelope contains these identities:

```text
record schema and version
store format version
record type and record ID
scope ID, generation, and sequence
prior-record digest
typed payload
```

The codec orders every JSON object key by its lexical byte value. It applies
the same rule to nested objects. The SHA-256 input is the complete canonical
byte sequence. Equivalent maps have the same bytes and digest.

A chain starts with `genesis`. Each later record names the digest of the prior
record and uses the next sequence. Chain validation reports the exact invalid
record for a changed digest, insertion, deletion, or reorder. The digest chain
detects accidental mutation and corruption. It is not an authentication claim
against the current operating-system user.

## Opaque Jidoka Value

Console stores a Jidoka session value in a separate logical envelope. The
envelope contains the Jidoka schema version, revision, canonical encoded byte
count, and digest. The encoded value is at most 128 MiB.

Console does not interpret the value as Console history. Decode verifies the
envelope, size, digest, and portable representation. It then calls the public
`Jidoka.Session.Data.new/1` contract. An invalid Jidoka schema does not produce
a replacement value.

## Sensitive and Runtime Values

Validation occurs before canonical encoding. It rejects credential fields,
inline authorization, URI user data, credential query data, interpolation,
shell credential arguments, renderer state, raw provider clients, PIDs,
references, ports, functions, and unsupported structs.

The validator does not resolve a credential source. It does not compare normal
prompt text with a secret value. Rejections contain a path, a reason code, and
a redacted marker. They do not contain the rejected value.

Credential profiles contain only stable source and reference identities. The
supported reference kinds are a declared environment variable, one private
dotenv file identity and variable name, or one existing keychain item identity.
Unknown metadata, free-form locators, shell text, values, fingerprints,
prefixes, suffixes, and lengths fail.

## Migrations

Store format, record schema, and Jidoka envelope versions are separate. A
migration step has an ID, source version, target version, SHA-256 checksum, and
deterministic transformation. Steps move one version at a time.

A second run at the target version returns `current` and does not change the
value. A future version returns `incompatible_future_store_format` and no
replacement value. The conformance function runs a transformation twice and
checks deterministic output and second-run idempotence.

The compatibility matrix and conformance fixtures are below
`priv/session/durable/`. Later storage work must use these contracts without
changing them inside an implementation pull request.
