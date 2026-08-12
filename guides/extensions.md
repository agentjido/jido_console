# CLI Extensions And Project Trust

Agent YAML and JSON request extensions by ID. They cannot supply a module,
process command, image, mount, network rule, or secret. The CLI gives an ID
meaning only through trusted host record files.

A record file has this form:

```yaml
version: 1
extensions:
  - id: acme.context
    source: built_in
    source_ref: registry:acme-context
    release: 1.0.0
    sha256: sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    permissions: [context, state]
    capabilities: [acme.context.run]
    modes: [interactive, automation]
    scope: user
    enabled: true
```

Process records use `source: process` and add a command list. The command is
trusted private configuration. The CLI resolves relative executables from the
record file, resolves symbolic links, and verifies the executable SHA-256 pin.
It then gives the record to the injected process descriptor resolver. Commands,
host paths, secrets, and child stdout never enter a plan, manifest, case result,
or session.

User records apply directly. Project records need a matching trust file entry:

```yaml
version: 1
projects:
  - root: /canonical/project/root
    repository_id: sha256:...
    extensions:
      acme.context: sha256:...
```

The key uses the canonical project root and repository identity. A project
record overrides a user record with the same ID only after this check. A pin
change removes trust. Automation never prompts. Unknown, disabled, changed,
untrusted, duplicate, or interactive-only records fail as configuration errors
before JSONL opens, with exit status 64.

Interactive, `jido run`, and `jido eval` use `Jidoka.Extension.Host`. Each
automation cell opens fresh instances and keeps state in its own session.
Extension results and portable UI data stay below their registered namespaces.
Trust evidence stays below `jido.cli.trust`. Runtime or close failure creates
one case error and exit status 1. Diagnostics use stderr. JSONL remains the only
automation stdout writer.

The CLI does not install, download, update, or discover packages. It has no
marketplace, signature system, hot reload, custom executable UI, MCP bridge, or
subagent activation in this phase.
