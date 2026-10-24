---
id: 28
title: Prediction call stacks and the conflict test as in ANTLR 4
status: open
labels: [parser]
depends: [17]
---

Two parts of issue 17's prediction differ from ANTLR 4 without saying so.

- **Call stacks.** `Gss` stores a configuration's stack as an interned,
  sorted set of frames, and `atnClosure` merges configurations that differ
  only in their stack into one with the union. That is coarser than ANTLR's
  `PredictionContext` graph (singleton and array contexts, merged with
  `merge` / local-context rules), so two configurations that ANTLR keeps
  apart can share a stack id here, and the reverse.
- **Conflict test.** `conflicting` says it is "ANTLR's termination test",
  but it requires *every* (state, context) group to hold two or more
  alternatives and every state too. ANTLR's SLL test is
  `hasConflictingAltSet` (*some* group has more than one) and
  `!hasStateAssociatedWithOneAlt`; full LL stops on
  `resolvesToJustOneViableAlt` or `allSubsetsConflict`. Stricter only means
  more lookahead, so it is safe, but the comment is wrong and full-LL
  ambiguity resolution can pick differently from ANTLR.

## Tasks

- [ ] Decide: port ANTLR's prediction contexts and merge, or keep the set
      representation and document why it is equivalent where it matters
- [ ] `conflicting` split into the SLL and LL tests ANTLR uses, with the
      right comments
- [ ] Tests where SLL conflicts and LL resolves, and real ambiguities that
      must pick the lowest alternative, compared with ANTLR's results
