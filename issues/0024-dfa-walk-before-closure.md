---
id: 24
title: Walk the prediction DFA before computing ATN closures
status: open
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

- [ ] Start state per (decision, precedence) in the cache; predict by walking
      DFA edges, falling back to the ATN only on a missing edge
- [ ] DFA edges as an `int`-indexed table, no closure on the hit path
- [ ] Config sets hashed and compared as values, not as `$`-joined strings
- [ ] Test: a repeat parse of the same input on a warm cache does (almost)
      no ATN work, for an SLL decision and for a precedence decision
