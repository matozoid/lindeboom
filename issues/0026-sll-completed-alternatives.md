---
id: 26
title: SLL prediction falls back to full LL whenever an alternative completes
status: open
labels: [parser, performance]
depends: [17]
---

In SLL mode, a configuration that reaches the stop state of the decision's
rule with an empty stack becomes `state: -1`. `predictOne` then returns `-2`
(retry in full LL) as soon as one alternative has completed while another is
still going, before looking at the current token, which may already rule one
of them out. The result is not stored in the DFA, so such a decision runs a
full-LL prediction on every call. With
`s : ('$' a | '@' b)* ; a : e ID ; b : e INT ID ; e : INT | ;` a repeat parse
of the same input costs 950 configurations against 972 the first time.

Every precedence rule hits this on every operator: the loop decision's exit
alternative is the rule's stop state, so it completes at once while the
operator alternatives continue. With
`e : e '*' e | e '+' e | e '+' '+' | INT ;` a repeat parse still does 528
configurations of full-LL work per 100 operators after issue 24.

ANTLR 4 keeps going in SLL: a configuration in a rule stop state with an
empty context can be followed by anything, it stays in the set, and only an
SLL conflict among the remaining alternatives sends the decision to full LL.

## Tasks

- [ ] Keep completed configurations in SLL; fall back to LL only on a real
      SLL conflict (or a decision that ends in rule stop states only, as
      ANTLR's `allConfigsInRuleStopStates`)
- [ ] Record the outcome in the DFA, including "needs full LL", so the next
      prediction from that state doesn't redo it
- [ ] Test: a context-sensitive decision like the one above, and a
      precedence loop decision, do no ATN work on a warm cache (as
      `parsegen_warm_dfa_does_no_atn_work` in `tparsegen`)
