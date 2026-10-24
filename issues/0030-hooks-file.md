---
id: 30
title: Grammar hooks in a Nim file
status: open
labels: [grammar, parser, lexer]
depends: [17]
---

Grammars that need code (semantic predicates in #22, lexer decisions that
modes in #21 cannot express, actions that build state) keep that code out of
the `.ldb` file. The grammar refers to hooks by name; their bodies are Nim
in a hooks file next to the grammar, which the generated lexer and parser
import. The grammar stays free of target code and readable as a grammar,
and the hooks are ordinary Nim: type-checked, testable and editable with
the usual tools.

## Design

### The hooks file

`<base>_hooks.nim` next to the grammar, where `<base>` is the generated
module base (`lua_hooks.nim` for `Lua`), or the file named by
`options { hooks = "file.nim"; }`. A grammar without hooks needs no file.

```antlr
prefixexp : ?isFunctionCall NAME ( '[' exp ']' | '.' NAME )* | ... ;
typedefName : ID !addTypedef ;
```

```nim
# c_hooks.nim
import lindeboom/runtime/hooks

type State* = object
  typedefs: HashSet[string]

func isTypeName*(p: PredicateView[State]): bool =
  p.look(1).text in p.state.typedefs

proc addTypedef*(p: ActionView[State]) =
  p.state.typedefs.incl p.last.text
```

The exact grammar syntax for a predicate (`?name`) and an action (`!name`)
is open; it must not look like ANTLR's `{...}` target code, which stays a
grammar error.

### Kinds of hook

- **Predicates** are `func`s, so Nim rejects side effects at compile time.
  Prediction evaluates them on alternatives the parser may never take, any
  number of times. A predicate sees the lookahead (`look(k)`, type and
  text), the tokens already matched in its rule, the rule stack, and
  `State`, read-only.
- **Actions** are `proc`s that run after the element before them matched,
  in the real parse only, never during prediction (as in ANTLR). They may
  change `State`. They do not build or change the tree.
- **Lexer hooks**: predicates on lexer rules, and scanners that match a
  token the DFA cannot, such as Lua's `[==[ ... ]==]` or a heredoc whose
  terminator is in its first line. Mode transitions stay declarative in
  #21's `modes` block.

`State` is optional. With it, a generated parser takes an initial state
and gives back the final one; the lexer and the parser share it, so a
parser action can steer a lexer hook only through tokens not yet lexed,
which needs lazy lexing (see Open questions).

### `lindeboom parse` and parity

The interpreter cannot run Nim. For a grammar with hooks, `lindeboom parse`
generates the lexer and parser, writes a small driver that prints what the
interpreter prints, builds it with `nim c` into a cache directory keyed by
a hash of the grammar, the hooks file and the Lindeboom version, and runs
it. Generated parsers and `lindeboom parse` then run the same code, so they
agree by construction. The first run takes a few seconds; later runs reuse
the binary while the hash matches. Without `nim` on the path,
`lindeboom parse` stops with a message that says so.

Grammars without hooks keep the interpreter as now, and the tests that
compare it with generated parsers keep covering prediction and recovery.

Not chosen:

- Embedding the NimScript VM in the CLI: it links the compiler into
  Lindeboom, ties it to one Nim version, and the VM's differences from
  native Nim put parity at risk again.
- The interpreter rejecting grammars with hooks: `lindeboom parse` would
  stop working for exactly the grammars that need the most debugging.

### Checking hooks

The generator does not read the hooks file. The generated code checks each
hook with `when not compiles(...)` and an `{.error.}` that names the hook,
its kind, the expected signature and the grammar rule and position, so a
missing or mistyped hook is reported in grammar terms rather than as a Nim
overload error.

### Prediction

See #22: a cached SLL state where a predicated alternative survives holds
the predicate, not a decision, and the predicate runs each time the state
is reached. Actions never run during prediction.

## Sample grammars

The design must be driven by real grammars that cannot be written without
these features, not by toy cases. Each kind of hook needs at least one
grammar from [grammars-v4](https://github.com/antlr/grammars-v4) ported
and parsing real input. The hook bodies below are in the grammars' Java
base classes (`<dir>/Java/*Base.java`).

Parser predicates on lookahead only:

- `lua/LuaParser.g4`: `IsFunctionCall()` reads `LT(1)` and `LT(2)` (#22).
- `golang/GoParser.g4`: `isNotReceive()` checks `LT(2) != RECEIVE`;
  `closingBracket()` checks for `)`, `}` or EOF.

Parser predicates on hidden tokens:

- `javascript/javascript/JavaScriptParser.g4`: `notLineTerminator()`
  guards `return`, `break`, `continue`, `throw` and `yield` (automatic
  semicolon insertion). It looks at the token before the current one on
  the hidden channel, so the predicate view must expose hidden tokens.

Parser predicates on `State` built by actions:

- `c/CParser.g4`: the typedef problem. `{this.EnterDeclaration();}` after
  a declarator records the declared name, `{this.EnterScope();}` and
  `{this.ExitScope();}` around `'{' blockItemList? '}'` scope it, and
  predicates such as `IsTypedefName()`, `IsCast()`,
  `IsSomethingOfTypeName()`, `IsDeclaration()` and `IsStatement()` read
  the table. `EnterDeclaration` reads the declarator subtree just parsed,
  so an action needs the current rule's matched children, not only the
  last token.
- `golang/GoParser.g4`: `{this.addImportSpec();}` adds an imported
  package name, read from the rule's `packageName` child, to a table that
  `isOperand()`, `isMethodExpr()` and `isTypeArgument()` consult.

Lexer predicates and actions on lexer state:

- `javascript/javascript/JavaScriptLexer.g4`: `IsRegexPossible()`
  decides `/` between regex and division from the last token produced;
  `ProcessOpenBrace()`/`ProcessCloseBrace()` keep a strict-mode stack and
  a template depth stack that `IsInTemplateString()` reads; `IsStrictMode()`
  turns `let`, `public` and friends into keywords.
- `rust/RustLexer.g4`: `SOF()` for the shebang; `FloatDotPossible()`
  reads the characters after the `.` so `1..2` and `1.max(2)` are not
  floats; `FloatLiteralPossible()` reads the last two tokens so `t.0.1`
  is tuple indexing. Lexer views need character lookahead and the
  previous tokens.

Lexer scanners and matching delimiters:

- `lua/LuaLexer.g4`: `COMMENT: '--' { this.HandleComment(); }` consumes a
  `--[==[ ... ]==]` long comment by counting `=`s.
- `sql/postgresql/PostgreSQLLexer.g4`: dollar-quoted strings push their
  tag (`PushTag()`) and end only where `IsTag()` sees the same tag.
- `php/PhpLexer.g4`: `ShouldPushHereDocMode(1)` for heredocs, and
  `PopModeOnCurlyBracketClose()` for `{$...}` in strings, together with
  #21's modes.

What these require of the views, beyond the sketch above: hidden tokens
in predicates, the current rule's matched children in actions, scope
entry and exit as actions around a block, character lookahead and the
previous tokens in lexer predicates, and lexer state stacks that
predicates read.

## Open questions

- The grammar syntax for predicates and actions, and whether a predicate
  may sit only at the start of an alternative (ANTLR's gating predicates)
  or anywhere.
- Whether actions may see labels of the current rule, and how: by name, as
  generated fields of the view.
- Lexer hooks and `State` changed by parser actions: today the lexer runs
  to the end before parsing starts. Feedback from parser to lexer needs
  lazy lexing, which also changes how prediction reads lookahead. Out of
  scope at first: lexer hooks see only lexer state.
- How `lindeboom parse --tokens` and `--tree` options reach the compiled
  driver, and where the cache lives (`$XDG_CACHE_HOME/lindeboom`).
- Whether `lindeboom gen --standalone` copies `runtime/hooks` like the rest
  of the runtime.

## Tasks

- [ ] Grammar syntax for predicate and action references; AST nodes with
      their position; checks for placement and names
- [ ] `options { hooks = ... }` and the default hooks file name
- [ ] `runtime/hooks`: `PredicateView`, `ActionView` and the lexer views,
      with `State` as a type parameter
- [ ] Generated lexer and parser import the hooks file and call the hooks;
      `when not compiles` checks with grammar-level messages
- [ ] Actions run after their element in the real parse only; a test that
      prediction never runs one
- [ ] `lindeboom parse` builds and caches a driver for a grammar with hooks,
      with the same output and exit codes as the interpreter
- [ ] Lexer scanner hooks for constructs that need counting, with a Lua
      long-bracket example
- [ ] Port one grammar per hook kind from Sample grammars, with its hooks
      in Nim, parsing real input from grammars-v4's `examples/`: at least
      C (typedefs via `State`), JavaScript (hidden-token predicate, regex
      vs division) and Lua (long brackets)
- [ ] Tests: hooks in generated parsers, `lindeboom parse` output equal to a
      generated parser's, a missing and a mistyped hook, the cache reused
      and rebuilt
- [ ] README: hooks file, hook kinds, `lindeboom parse` needing `nim` for
      grammars with hooks; remove "actions" from the unsupported list
