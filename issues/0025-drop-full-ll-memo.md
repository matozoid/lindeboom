---
id: 25
title: Drop the unbounded full-LL prediction memo
status: done
labels: [parser, performance]
depends: [17]
---

Full-LL prediction caches its results in `PredictionCache.entries`, keyed by
a string of the decision, precedence, the whole parser call stack (return
states and precedences) and every lookahead token kind seen so far. The key
is rebuilt and looked up on every token. The cache is a module-level variable
of the generated parser, kept across parses, and is never trimmed, so it
grows with every distinct stack and lookahead: deep nesting or many different
inputs keep adding entries. The interned call stacks in `Gss` grow the same
way.

ANTLR 4 does not cache full-context predictions; only the SLL DFA is kept.

## Tasks

- [x] Remove `entries` and the per-token key building from full-LL prediction
- [x] Full-LL stacks in a per-prediction (or per-parse) structure, not in the
      shared cache, so the module-level cache holds only the DFA
- [x] Check the `tparsegen` work bounds and the fuzz suite still pass

## Outcome

`entries` and its key are gone. Each full-LL prediction has a `Gss` of its
own, so the shared cache holds only the SLL DFA and the stacks of its
configurations. `cachedStacks` counts those;
`parsegen_full_context_keeps_nothing_in_the_cache` checks that nesting
deeper under a full-context decision adds none (with the shared `Gss` the
count went 7, 11, 31 for depths 2, 3 and 20).
