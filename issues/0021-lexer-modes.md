---
id: 21
title: Lexer modes
status: open
labels: [lexer, grammar]
depends: [2]
---

Support lexer modes in the spirit of ANTLR 4. All lexer rules currently
share one DFA, which cannot express context-dependent tokenization: string
interpolation, embedded HTML/JavaScript, heredocs, and similar constructs
need different rules while inside a region.

- [ ] Decide the grammar surface: a central `modes` block (see Design)
      instead of per-rule `mode`, `pushMode` and `popMode` commands. Decide
      whether `more` belongs in the same change and whether the ANTLR syntax
      is accepted as sugar.
- [ ] Add modes to the AST; rules in the default mode and later modes keep
      global token kinds but belong to one mode.
- [ ] Check mode declarations and transitions: lexer rules only, defined
      modes, duplicate modes, and rules not listed under a mode belonging to
      `DEFAULT_MODE`.
- [ ] Build one DFA per mode and emit per-mode tables in the generated lexer.
- [ ] Add a mode stack to the lexer runtime; select the current mode's table,
      apply mode transitions, and keep EOF/error behavior correct.
- [ ] Keep `lindeboom parse --tokens`, the interpreter, and generated lexers
      on the same table-driven path.
- [ ] Define how modes interact with the indentation filter and hidden tokens.
- [ ] Warn about modes that can never be entered or rules that can never match.
- [ ] Test mode switching, push/pop, nested modes, skip/hidden/type
      transitions, malformed mode stacks, interpreter/generated parity, and
      generated code compilation.
- [ ] Document modes in `README.md` and remove them from the unsupported list.

## Design

The aim is a grammar surface that is declarative and checkable, with no
target-language code and no per-rule mode commands. The `indentation` block
is the model: one block in the grammar, one table-driven implementation in
the runtime, shared by generated lexers and `lindeboom parse`.

- Declare modes and the rules in them in one `modes { ... }` block. A rule
  carries no commands; entering and leaving a mode is a transition on a token
  produced by a rule in that mode:

  ```antlr
  modes {
    DEFAULT : on '"'  -> push String;   // rules not listed stay here
    String  : rules StringText StringEscape;
              on '"'  -> pop;
              on '${' -> push Expr;
    Expr    : rules ...;                // ordinary tokens
              on '}'  -> pop;
  }
  ```

  The exact surface is still open, but `push` and `pop` should be the only
  state changes, rules not named in the block keep belonging to
  `DEFAULT_MODE`, and the generator should still emit one DFA per mode with
  one runtime stack.

- Keep common constructs as sugar, not required syntax: a `with
  interpolation` option on a string rule, a heredoc form, or an
  `embedded(Html)` rule can expand to the block above. Sugar must be a pure
  expansion, not a separate code path, so `--tokens`, the interpreter, and
  generated lexers stay identical.

- Do not make ANTLR's `mode NAME;` / `pushMode` / `popMode` commands the
  primary surface. They scatter state changes through the rules, put the
  mode structure in two places, and are hard to check for reachability. If
  compatibility matters, accept them as sugar that desugars to the block.

- Parser-driven (scannerless) lexing would remove modes entirely, but it
  needs lazy tokenization and changes how ALL(*) prediction and error
  recovery see the input. Out of scope.

- Modes do not solve constructs that need counting (`[==[`, heredoc
  terminators). Those still need bounded rule expansion or a lexer
  scanner hook (#30).

- Interactions to settle: hidden tokens and the indentation filter keep
  working per mode; `skip` can cross a mode boundary; EOF pops every open
  mode or reports an unterminated region, matching `EOF -> popMode`.

## Sample grammars

No grammar in this repo uses modes yet. These ANTLR 4 grammars do, and
between them cover the constructs the checks and runtime must support:

- [ANTLRv4Lexer.g4](https://github.com/antlr/grammars-v4/blob/master/antlr/antlr4/ANTLRv4Lexer.g4)
  — `mode Argument` and `mode LexerCharSet`. A nested `[` pushes the same
  mode again, a `more` rule builds the character-set body, and
  `EOF -> popMode` handles unterminated input:

  ```antlr
  mode Argument;
  NESTED_ARGUMENT       : '[' -> type(ARGUMENT_CONTENT), pushMode(Argument) ;
  END_ARGUMENT          : ']' { this.handleEndArgument(); } ;
  UNTERMINATED_ARGUMENT : EOF -> popMode ;
  ARGUMENT_CONTENT      : . ;
  ```

- [PhpLexer.g4](https://github.com/antlr/grammars-v4/blob/master/php/PhpLexer.g4)
  — HTML by default; `<?php` and `<?=` push `PHP`, `?>` pops. `mode XML`,
  `INSIDE`, `SCRIPT` and `STYLE` handle embedded markup; `<<<NAME` pushes
  `HereDoc`, and `"` pushes `InterpolationString`, which pushes `PHP` again
  for `${...}`. Exercises `skip`/hidden/`type` together with nested
  push/pop.
- [JavaScriptLexer.g4](https://github.com/antlr/grammars-v4/blob/master/javascript/javascript/JavaScriptLexer.g4)
  — template literals: `` '`' -> pushMode(TEMPLATE) ``, `${` switches back
  to `DEFAULT_MODE`, and the closing backtick pops. Closest to ordinary
  string interpolation.
- [STLexer.g4](https://github.com/antlr/grammars-v4/blob/master/stringtemplate/STLexer.g4)
  — `mode Inside` and `mode SubTemplate`, entered and left from template
  delimiters; also uses lexer predicates (#22). Good for checking how modes
  interact with hidden tokens.

`PhpLexer.g4` is also the best test for the indentation filter: heredoc
text and HTML are multiline and must not produce indent/dedent tokens.
