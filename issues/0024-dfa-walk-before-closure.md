---
id: 24
title: Walk the prediction DFA before computing ATN closures
status: done
labels: [parser, performance]
depends: [17]
---

The SLL DFA cache of issue 17 saves almost no work. Every step of
`predictOne` (`runtime/parser.nim`) first runs `atnClosure` on the current
configurations, then builds a string key of the whole set (`configSetKey`) to
find its DFA state, and only then follows the cached transition. A warm cache
still pays a closure and a string build per token.

Measured with `predictionWork` on one cache, `s : a* ; a : ID ID 'x' | ID ID 'y' ;`:

```
n=100  work=1100   first parse
n=100  work=1100   same input again
n=1000 work=11000
```

With a real DFA walk the second parse would be close to 0.

ANTLR 4 keeps a start state per decision (per precedence for precedence
decisions) and walks `s0 --token--> s1 --> ...` until a state with a
prediction or a missing edge; only a missing edge computes `reach` and
`closure` over the ATN and adds the new state and edge.

## Tasks

- [x] Start state per (decision, precedence) in the cache; predict by walking
      DFA edges, falling back to the ATN only on a missing edge
- [x] DFA edges as an `int`-indexed table, no closure on the hit path
- [x] Config sets hashed and compared as values, not as `$`-joined strings
- [x] Test: a repeat parse of the same input on a warm cache does no ATN
      work, for an SLL decision (the precedence one moved to issue 26)

## Closing note

`predictOne` is now `predictSll` and `predictLl`. `predictSll` keeps a
start state per (decision, precedence) in `dfaStarts` and walks the edges;
a missing edge runs `sllTarget`, which computes reach and closure once and
stores the new state and edge, including "no viable alternative" (an empty
state resolved to the loop exit or a retry). A state that needs full
context is resolved to -2 when it is created. DFA states are keyed by
`DfaKey`, the decision, precedence and sorted configurations, hashed as
values. `predictLl` is the old full-context loop, unchanged.

Same probe as above, now:

```
SLL  n=100 work=12 / repeat 0 / n=1000 0     (was 1100 / 1100 / 11000)
LL   n=100 work=477 / repeat 450 / n=1000 4500   (was 972 / 950 / 9500)
prec n=100 work=587 / repeat 528 / n=1000 5328   (was 1249 / 1200 / 12000)
```

The remaining work is all full LL. Every precedence loop decision goes
there: its exit alternative leaves the rule at once while the operator
alternatives continue, which `needsFullContext` sends to a retry. That is
issue 26, which now has the precedence test.

Test: `tparsegen` `parsegen_warm_dfa_does_no_atn_work`.
