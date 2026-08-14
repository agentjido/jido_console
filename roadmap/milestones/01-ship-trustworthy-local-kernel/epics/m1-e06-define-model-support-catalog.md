---
epic: M1-E06
type: epic
title: Define the Model Support Catalog
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e06
depends_on: [M1-E05]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E06: Define the Model Support Catalog

## Goal

Define the exact model support data that controls model selection and every v0.1 support claim.

## Scope

- Define supported, beta, available, and unsupported model tiers.
- Record the exact provider and model identity for each catalog entry.
- Record tested capabilities, limits, cost data, cancellation behavior, prompt-cache behavior, and known gaps.
- Define the catalog format and revision rules used by model commands and the TUI.
- Keep Ollama in the beta tier until its beta contract passes.
- Reject an entry that has no declared support tier or incomplete capability data.
- Link each claimed model to its provider contract evidence.

## Out of Scope

- Provider-specific contract execution
- Credential resolution
- Silent model or provider fallback
- Support claims without contract evidence
- Models for later releases

## Dependencies

This epic depends on M1-E05 for the model and settings selection boundary.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the model catalog schema, entries, validation, and focused tests. It must not add provider support claims without evidence.

## Acceptance Checks

- Every catalog entry has one exact provider and model identity.
- Every entry has one support tier and complete capability, limit, cost, cancellation, prompt-cache, and known-gap fields.
- Unsupported features and missing contract evidence cannot be presented as supported.
- Ollama remains beta until its declared beta contract passes.
- Catalog validation returns a focused error for an unknown tier, duplicate identity, or missing field.
- Model commands and the TUI can consume the same validated catalog data.

## Proof Artifacts

- Versioned model catalog schema
- Validated v0.1 catalog
- Catalog validation results
- Model identity and capability field table
- Links from catalog entries to provider contract evidence

## Milestone Traceability

This epic supplies the model support tiers and exact capability data required by the Milestone 1 model selection and support gates.
