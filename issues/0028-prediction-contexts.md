---
id: 28
title: Prediction call stacks and the conflict test as in ANTLR 4
status: in-progress
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

- [x] Keep the set representation, made canonical: `union` merges frames
      with the same return state and precedence into one over the union of
      their parents, as ANTLR merges array contexts, so a set of stacks is
      a trie from the top and equal sets get the same id (`tests/tgss.nim`).
      Not ported: ANTLR's SLL wildcard, where merging with the empty
      context gives the empty context. It would only coarsen SLL groups.
- [x] Full context stops as ANTLR's `resolvesToJustOneViableAlt` does
      (`settled`): taking the lowest alternative once every group conflicts
      could pick an alternative whose configurations all die later, as
      `x y y c` in `parsegen_full_context_waits_for_one_lowest_alternative`.
- [x] SLL keeps the stricter `conflicting` test, with a comment saying how
      it differs from `hasSLLConflictTerminatingPrediction` and why that
      is safe.
- [x] Closure keeps only configurations that can match a token, as ANTLR's
      `closure_`, so epsilon-only states no longer split groups.
- [x] At the end of the input SLL and full context step over an explicit
      `EOF` (`parsegen_explicit_eof_stays_in_sll`).
- [ ] Tests where SLL conflicts and LL resolves, and real ambiguities that
      must pick the lowest alternative, compared with ANTLR's results
