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

- [ ] All FullContextParsing descriptors
- [ ] The ParserExec descriptors that don't need actions beyond what a
      parse tree or error expectation can show
- [ ] The LeftRecursion descriptors (expressions, suffixes, prefixes,
      associativity, ternaries, `PrecedenceFilterConsidersContext` variants)
- [ ] The SemPredEvalParser descriptors on precedence; the others wait for
      issue 22
- [ ] Each one in the interpreter and as a generated parser, as now; a list
      in `tantlr.nim` of the descriptors left out and why
