# ADR 001: Keep ignore rules outside Alkaid

- Status: Accepted
- Date: 2026-09-15

## Context

File search needs to skip ignored paths, but interpreting Git ignore files is a
Git responsibility. Depending on one Git implementation would couple general
filesystem search to an unrelated component and release cycle.

## Decision

Accept ignore matchers through the single `ignored?(path, directory:)`
operation. Alkaid owns traversal and invokes the supplied matcher with paths
relative to the search root.

## Consequences

Callers may use any ignore implementation and Alkaid has no runtime gem
dependencies. Callers that need Git-compatible rules must construct and pass a
matcher themselves.
