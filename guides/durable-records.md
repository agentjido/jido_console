# Durable Records, Codecs, and Migrations

This guide describes the version 1 durable data contract. It defines data and
validation only. It does not open a file or database.

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
