---
id: 25
title: Drop the unbounded full-LL prediction memo
status: open
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

- [ ] Remove `entries` and the per-token key building from full-LL prediction
- [ ] Full-LL stacks in a per-prediction (or per-parse) structure, not in the
      shared cache, so the module-level cache holds only the DFA
- [ ] Check the `tparsegen` work bounds and the fuzz suite still pass
