# Tilde source governance

Status: Accepted as a design reference. No source reuse is approved by this record.

## Source

- Reviewed repository: `https://github.com/elixir-vibe/tilde.git`
- Reviewed commit: `9d4aa53b8f029a3f315b14bca78cd0bce7c8f3ac`
- Decision source: local planning commit `23d6c0bc70497c86775686298aa6ea1c95c64c31`, file `research/tilde-reference-notes.md`
- Publication limit: The planning repository has no public remote. The local commit is an internal decision reference, not a public source link.

Jido Console has not copied or adapted Tilde source. Tilde is not a runtime dependency.

## Approved pattern review areas

- Semantic sessions and ordered console events
- Transport-neutral interactions and renderer projections
- Supervised session ownership and client attachment
- Workbench state, widgets, and cross-client behavior tests

These items are ideas that a new design can use. This approval does not permit a source copy.

## Prohibited direct reuse

- File and command tools
- Session identity and storage lifecycle
- `/clear` and `/compact` behavior
- Demo authentication
- OpenRouter-only runtime gates

## Attribution and review

Each future source adaptation needs a separate review. The review must name the exact Tilde commit and files, map the change to an approved area, and confirm that it does not use a prohibited area. Before that change merges, it must add the applicable attribution to the root `NOTICE` file and prove that Tilde is not a runtime dependency.

There is no `NOTICE` change now because this change does not copy or adapt source. Beadwork item `jido_console-g0e11` owns changes to this boundary.
