---
id: 29
title: Port more of ANTLR 4's runtime test descriptors
status: open
labels: [parser, testing]
depends: [17]
---

Issue 17 asked for prediction to be tested thoroughly with the descriptors
of ANTLR 4's runtime test suite
(`runtime-testsuite/resources/org/antlr/v4/test/runtime/descriptors`).
`tests/tantlr.nim` has 9: 5 FullContextParsing, 3 ParserExec, 1
LeftRecursion and no SemPredEvalParser. ANTLR has dozens of LeftRecursion
descriptors alone, and the precedence ones are where prediction and
precedence climbing interact.

## Tasks

- [x] All FullContextParsing descriptors
- [x] The ParserExec descriptors that don't need actions beyond what a
      parse tree or error expectation can show, and the ParseTrees and
      Performance ones
- [x] The LeftRecursion descriptors (expressions, suffixes, prefixes,
      associativity, ternaries, `PrecedenceFilterConsidersContext` variants)
- [ ] The SemPredEvalParser descriptors on precedence; the others wait for
      issue 22
- [x] Each one in the interpreter and as a generated parser, as now; a list
      in `tantlr.nim` of the descriptors left out and why
- [x] A prediction mode that always uses full LL, and a test that SLL
      first gives the same trees and diagnostics on the descriptors and the
      fuzz inputs: what issue 26 changes must not change a parse

## Progress

FullContextParsing and LeftRecursion come first because issue 26 changes
SLL prediction for every precedence rule. They are in `tests/antlr`, one
file per descriptor in its group's directory: the grammar rewritten
mechanically (actions, alternative labels and `{<True()>}?` removed,
implicit tokens declared), the input, and ANTLR's `toStringTree` output.
The descriptors that print through actions were ported by hand, with the
tree ANTLR's prediction gives; for return values, the tree whose value the
descriptor prints. `tantlr.nim` turns `treeRepr` into `toStringTree` form,
groups the files by grammar and runs each grammar in the interpreter and
as one generated parser.

97 of 98 LeftRecursion descriptors and 12 of 15 FullContextParsing ones
are in, either there or written out in `tantlr.nim`, and all pass with the
prediction of issue 24. Left out, as `tantlr.nim` lists: SemPredFailOption
(a failing predicate), ExprAmbiguity_1 and _2 (rule arguments), and
FullContextIF_THEN_ELSEParse_6, the same as _5.

44 of 50 ParserExec descriptors, 4 of 10 ParseTrees and all 7 Performance
ones are in too. They found two bugs: with `('x' | 'x' 'y') EOF EOF`
prediction at the end of the input stepped over only one `EOF`
(MultipleEOFHandling), and a label such as `id_` gave an accessor that is
not a Nim identifier (Labels). Left out, as `tantlr.nim` lists:
no tree-less or SLL-only mode, non-greedy `??`, semantic predicates, and
the ParseTrees trees after error recovery, which differs from ANTLR's.

`newPredictionCache(fullContextOnly = true)` skips SLL and predicts every
decision in full context; `fullContextOnly(a)` in `codegenhelpers` gives an
`Analysis` that uses it. `tantlr` and `tfuzz` check that the interpreter
gives the same output with it as with SLL first. Letting SLL pick the
lowest alternative where it now retries in full LL fails both suites.
