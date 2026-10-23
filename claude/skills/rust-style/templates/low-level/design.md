# <crate>: <one-line purpose>

| | |
| --- | --- |
| Author | <name> |
| Date | <YYYY-MM-DD> |
| Status | Draft / Implemented at <version> |
| Crate | `<crate>` <version>, edition 2024, Rust <MSRV> or later |
| Dependencies | none. `cargo tree` has no dependency edges |
| Read path | <sync / async, what it touches> |
| Transport | <thread model, I/O> |
| Unsafe | none |

## Overview

What the crate is, for whom, and the one sentence a reader must remember.

## Background and prior art

What callers need, what exists (crates, systems), and why each was not used.

## Goals and non-goals

### Goals

### Non-goals

## Design

Data structures, ownership, locking, and the hot path with its cost.

## Wire or storage format

Byte layout, versioning, limits.

## Failure modes

Torn and partial writes, panics in user code, poisoned locks, reconnects, limits hit; what
state survives each and what the caller does next.

## MSRV

The version and the feature that requires it.
