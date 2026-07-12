---
inclusion: auto
name: runplay-architecture
description: Use when changing package targets, module boundaries, shared models, persistence, concurrency, or code spanning RunPlayCore, RunPlayPlatform, and RunPlayStudio.
---

# RunPlay Studio architecture references

Use the live repository sources rather than duplicating architecture here.

The allowed dependency direction is:

`RunPlayStudio → RunPlayPlatform → RunPlayCore`

Reverse dependencies are forbidden.

Architecture: #[[file:docs/architecture.md]]
Package graph: #[[file:Package.swift]]
Data model: #[[file:docs/data-model.md]]
