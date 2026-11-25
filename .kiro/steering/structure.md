---
inclusion: auto
name: runplay-architecture
description: Use when changing package targets, module boundaries, shared models, persistence, concurrency, or code spanning RunPlayEngine, RunPlayCore, RunPlayPlatform, and RunPlayStudio.
---

# RunPlay Studio architecture references

Use the live repository sources rather than duplicating architecture here.

The allowed dependency direction is:

`RunPlayStudio → RunPlayPlatform → RunPlayCore → RunPlayEngine`

Reverse dependencies are forbidden. `RunPlayEngine` is the pure Swift
computational engine; only `RunPlayCore` imports it. The engine rules live in
root `AGENTS.md` under "Architecture Boundaries" and "Swift engine policy
(defaults)".

Architecture: #[[file:docs/architecture.md]]
Engine boundaries and verification: #[[file:docs/engine.md]]
Package graph: #[[file:Package.swift]]
Data model: #[[file:docs/data-model.md]]
