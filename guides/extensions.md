# CLI Extensions And Project Trust

An agent source supplies behavior. A host coding pack supplies interactive
coding tools and workspace context. An execution policy supplies permission
and isolation rules. These inputs stay separate when Console builds the bound
agent specification.

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
change removes trust. Unknown, disabled, changed, untrusted, or duplicate
records fail as configuration errors.

The interactive terminal uses `Jidoka.Extension.Host`. Each session opens fresh
extension instances. Extension results and portable UI data stay below their
registered namespaces. Trust evidence stays below `jido.cli.trust`.

The CLI does not install, download, update, or discover packages. It has no
marketplace, signature system, hot reload, custom executable UI, MCP bridge, or
subagent activation in this phase.
