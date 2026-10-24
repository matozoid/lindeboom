---
id: 22
title: Semantic predicates
status: open
labels: [parser, grammar]
depends: [17, 30]
---

Support semantic predicates so a grammar can reject an alternative based on
context that the ALL(*) lookahead alone cannot settle. Today target code in
a grammar is rejected. ANTLR 4's `{ ... }?` is the reference for the use
cases and for how predicates take part in prediction; the surface is a
named predicate hook from #30, not target code in the grammar.

- [ ] Predicate references in parser rules (syntax from #30), with their
      source position; checks for placement
- [ ] Prediction: drop alternatives whose predicate fails before
      committing; cached SLL states where a predicated alternative survives
      hold the predicate instead of a decision (see Design)
- [ ] Full-context prediction and error recovery with predicates: what a
      decision reports when every viable alternative's predicate fails
- [ ] Generated parsers call the predicate hook where its alternative is
      considered
- [ ] `lindeboom parse` runs grammars with predicates through #30's compiled
      driver, so it cannot disagree with generated parsers
- [ ] Tests: gated alternatives, predicates in ALL(*) decisions, a predicate
      reading `State` set by an action, failing predicates in recovery, and
      the 25 remaining SemPredEvalParser descriptors (#29)
- [ ] Document the syntax and limitations, and remove semantic predicates
      from the unsupported list

## Design

A predicate is a Nim `func` in the grammar's hooks file (#30), referred to
by name:

```antlr
prefixexp : ?isFunctionCall NAME ( '[' exp ']' | '.' NAME )* | ... ;
```

```nim
func isFunctionCall*(p: PredicateView[State]): bool =
  p.look(2).kind != OP
```

Being a `func`, it cannot have side effects, so prediction may evaluate it
on alternatives it then discards, and any number of times. It reads the
lookahead, the tokens and labels already matched in its rule, the rule
stack, and the user `State` that actions (#30) write. That last part
covers C's typedef table, which a fixed expression language could not.

### Prediction

The SLL DFA cache assumes a decision depends only on the tokens ahead. A
predicate reading `State` breaks that, so, as in ANTLR:

- Closure records, per configuration, the predicates passed on the way
  from the decision; a predicate after the first token of its alternative
  is not evaluated during prediction (ANTLR's rule for actions in the
  middle of an alternative applies to predicates past the decision).
- A DFA state whose configurations still disagree on the alternative only
  because of predicates is stored with the predicate per alternative, not
  with a decision. Reaching it evaluates the predicates in alternative
  order each time; results are never cached.
- States without predicated alternatives are cached as now, so grammars
  without predicates pay nothing.
- If every surviving alternative's predicate fails, the decision reports
  no viable alternative, like a token mismatch.

### Earlier design, dropped

This issue first proposed a built-in, side-effect-free expression language
(`[next != OP]`) so the interpreter could evaluate predicates itself, and
rejected named predicates bound by the host program because `lindeboom
parse` could then no longer run the grammar standalone. #30 removes that
objection: for a grammar with hooks, `lindeboom parse` compiles and runs
the generated parser, so it and generated parsers run the same code. A Nim
`func` is then simpler than a new language and covers more (the symbol
table case), and Lua's `IsFunctionCall` is one line in it.

### Out of scope

- Lexer predicates (`isLDelim`, `opened`) belong to #30's lexer hooks and
  #21's modes.
- Resolving an ambiguous parse in a host-side post-pass is a separate API
  and a tree-shape problem.

## Sample grammars

Real grammars use predicates for exactly the choices ALL(*) cannot settle.
They show the range of state a predicate may need, from lookahead only to a
symbol table:

- [LuaParser.g4](https://github.com/antlr/grammars-v4/blob/master/lua/LuaParser.g4)
  — the simplest case: a lookahead-only predicate separating a call
  statement from an assignment target when both start with `NAME`:

  ```antlr
  prefixexp
      : { this.IsFunctionCall() }? NAME ( '[' exp ']' | '.' NAME )*
      | functioncall ( '[' exp ']' | '.' NAME )*
      | '(' exp ')' ( '[' exp ']' | '.' NAME )*
      ;
  ```

  `IsFunctionCall()` only inspects `LT(1)` and `LT(2)`; it reads no parse
  state. A token/lookahead predicate covers this one. See #23 for why this
  rule looks the way it does.

- [CParser.g4](https://github.com/antlr/grammars-v4/blob/master/c/CParser.g4)
  — gated alternatives for the typedef/identifier problem, which need a
  declaration symbol table built up while parsing:

  ```antlr
  unaryExpression
      : ...
      | {!this.IsSomethingOfTypeName()}? 'sizeof' unaryExpression
      | {this.IsSomethingOfTypeName()}? 'sizeof' '(' typeName ')'
      ;
  castExpression
      : {this.IsCast()}? '(' typeName ')' castExpression
      | unaryExpression
      ;
  declaration
      : declarationSpecifiers
        ( {this.IsInitDeclaratorList()}? initDeclaratorList | ) ';'
      ;
  ```

  This is the upper bound. With #30, actions on declarations record
  typedef names in `State`, and these predicates read it.

- [Python3Parser.g4](https://github.com/antlr/grammars-v4/blob/master/python/python3/Python3Parser.g4)
  — two alternatives with the same token prefix but different meanings:

  ```antlr
  literal_expr
      : signed_number { this.CannotBePlusMinus() }?
      | complex_number
      | strings
      | ...
      ;
  pattern_capture_target
      : name { this.CannotBeDotLpEq() }?
      ;
  ```

  The Python target implements these helpers as stubs, but the placement
  and the shape of the generated check are still representative.

- [STLexer.g4](https://github.com/antlr/grammars-v4/blob/master/stringtemplate/STLexer.g4)
  — lexer predicates selecting delimiters and mode switches, e.g.
  `LDELIM : . { this.isLDelim() }? -> mode(Inside)` and
  `LBRACE : LBrace { this.startsSubTemplate() }? -> mode(SubTemplate)`.
  These are #30's lexer hooks, not parser predicates.
