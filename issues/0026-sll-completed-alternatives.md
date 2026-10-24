---
id: 26
title: SLL prediction falls back to full LL whenever an alternative completes
status: done
labels: [parser, performance]
depends: [17]
---

In SLL mode, a configuration that reaches the stop state of the decision's
rule with an empty stack becomes `state: -1`. Since issue 24,
`needsFullContext` (`runtime/parser.nim`) resolves a DFA state to `-2`
(retry in full LL) when it is created, as soon as one alternative has
completed while another is still going, before looking at the next token,
which may already rule one of them out. The `-2` is stored in the DFA, so
SLL is cheap on a warm cache, but every such prediction then runs full LL.

Every precedence rule hits this on every operator: the loop decision's exit
alternative is the rule's stop state, so it completes at once while the
operator alternatives continue. With
`e : e '*' e | e '+' e | e '+' '+' | INT ;` a repeat parse still does 528
configurations of full-LL work per 100 operators after issue 24. It is only
this cheap because of the full-LL memo, which issue 25 removes, so this
issue comes first.

## What ANTLR 4 does

A configuration in a rule stop state with an empty context does not match
any token. In SLL, `closure` follows the stop state's epsilon edges to the
follow state of every call site of the rule (the global FOLLOW), with an
empty context, and goes on from there; in full LL it stays as a stop-state
configuration. Only an SLL conflict among the remaining configurations
sends the decision to full LL.

Global FOLLOW alone does not fix precedence loops. The exit alternative's
FOLLOW leads back into the caller's loop of the same rule, which matches the
same operator and reaches the same ATN state and context as the operator
alternative, so the two conflict. ANTLR resolves this with
`applyPrecedenceFilter` on the start state of a precedence decision: a
configuration of the continue alternative hides any configuration of another
alternative with the same state and context (unless
`precedenceFilterSuppressed`). That is what makes left-recursive rules greedy
in SLL.

## Notes

- Our ATN has no edges from a rule's stop state to its follow states. Build
  a table from each rule to the return states of its call sites
  (`atCall` edges) once, as `prepare` builds `stopRules`.
- A rule may be an entry rule, so its global FOLLOW also includes the
  bottom of the stack (`state: -1`, accepted only at EOF).
- The caller's precedence is unknown on a global-FOLLOW return; use the
  most permissive one (0). Over-approximating is sound in SLL: a single
  surviving alternative is right, and a conflict goes to full LL.
- The loop exit is `high(int)` in `alternativeIds`; the precedence filter
  keeps the other alternatives' configurations over the exit's.
- Some decisions really need the caller's context and still go to full LL
  every time, as in ANTLR. In
  `s : ('$' a | '@' b)* ; a : e ID ; b : e INT ID ; e : INT | ;`
  the two alternatives of `e` meet in the same state with an empty context
  after `a` or `b`: a real SLL conflict. With global FOLLOW SLL gets further
  before it gives up, but the full-LL work stays.
- `conflicting` is stricter than ANTLR's SLL test; that is issue 28, not
  this one.

## Tasks

- [x] Global FOLLOW in SLL closure: a stop-state configuration with an empty
      stack continues at every call site's return state, and stays as
      `state: -1` for entry rules
- [x] Remove `needsFullContext`; fall back to LL only on an SLL conflict,
      or at EOF with more than one accepted alternative (check against
      ANTLR's `allConfigsInRuleStopStates` and `skippedStopStates`)
- [x] Precedence filter on precedence-decision start states, as ANTLR's
      `applyPrecedenceFilter`, with its `precedenceFilterSuppressed`: an exit
      configuration that left through a call of precedence 0 is kept, since
      it may continue inside an outer loop alternative
      (LeftRecursion `ReturnValueAndActionsList1`)
- [x] Two-stage parsing, as ANTLR: with global FOLLOW, SLL can settle a
      choice through a caller that is not the real one, before full context
      would see a syntax error, and then errors and recovery differ (fuzz:
      `calc ... c()c()` in `features.ldb`, `loop a<EOF>` in `ambiguous.ldb`).
      A parse with a syntax error is redone with full-context prediction
      only (`retryInFullContext`), so errors are those of full context.
- [x] Tests, as `parsegen_warm_dfa_does_no_atn_work` in `tparsegen`:
  - [x] `s : a ID ; a : ID | ;` (needs only global FOLLOW): no ATN work on
        a warm cache
  - [x] a precedence loop decision: no ATN work on a warm cache
  - [x] the context-sensitive decision above: right trees for both `$` and
        `@` inputs, full LL only for `e`'s decision
- [x] Interpreter and generated parsers still agree; `tantlr` and the fuzz
      suite pass
