# ANTLR 4 runtime test descriptors

Converted from the descriptors of ANTLR 4's runtime test suite,
`runtime-testsuite/resources/org/antlr/v4/test/runtime/descriptors`, at
commit 7d5770395bb7b02eb56e7c62662cb1d7c08f42a3. ANTLR is under the BSD
license in `LICENSE.txt`. `tests/tantlr.nim` runs every file here, in the
interpreter and as a generated parser.

One file per descriptor, under its group's directory, with the same name.
Sections:

- `[grammar]`: the descriptor's grammar, rewritten to what Lindeboom
  supports;
- `[start]`: the start rule, which must be the first parser rule;
- `[input]`: the input as a Nim string literal;
- `[tree]`: the expected tree as ANTLR's `toStringTree` prints it, without
  `<EOF>`. Without it the input only has to parse without errors.

The grammars were rewritten mechanically: `@after` and `@init` blocks,
empty actions and `{<True()>}?` predicates are removed, `\<` is `<`,
the `<p=...>` and `<fail=...>` options of those predicates are removed,
`x+=e` is `x=e`, alternative labels are removed (ANTLR's trees name nodes
by rule), and tokens used without a lexer rule are declared in `tokens`.
Descriptors that print with actions instead of `toStringTree` were ported
by hand, with the tree ANTLR's prediction gives: for the LeftRecursion
ones with return values, the tree whose value the descriptor prints (`a=b+c`
printed as `((a=b)+c)`, `i++*3` as 12).

Where the start rule was not the first parser rule, it was moved first.
The ParseTrees descriptors print `$r.ctx` from inside the start rule `s`,
so their trees are wrapped in `(s ...)`. ParserExec descriptors that print
tokens or text through actions were ported by hand with the tree ANTLR
builds. In OpenDeviceStatement_Case3 ANTLR's start rule `statement`
matches only a prefix of the input, as it does not end in `EOF`; here the
start rule must match all of it, so the port starts at `program`.
SemPredEvalParser's AtomWithClosureInTranslatedLRRule writes out by hand
the translation ANTLR gives a left-recursive rule, with the precedence as
an argument and a predicate; the port is the left-recursive rule itself.
