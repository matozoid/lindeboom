# Lindeboom

Lindeboom is a parser generator for Nim. It reads a grammar in ANTLR 4
syntax (a `.ldb` file) and generates a lexer and a recursive-descent parser
as plain Nim modules. The parser builds a parse tree that you walk with
`case n.kind`.

- Grammars in a separate file, readable by anyone who knows ANTLR.
- Indentation-based languages, such as Python, need no hand-written lexer
  code: an `indentation` block in the grammar produces the `INDENT` and
  `DEDENT` tokens.
- Left-recursive expression rules, with precedence by the order of the
  alternatives, as in ANTLR.
- Syntax errors are recovered from, reported with positions, and kept as
  data, so a program can word them itself.
- The generated code depends only on a small runtime, which can be copied
  next to it.
- A command-line tool checks grammars, generates code, and runs a grammar
  on input without generating anything.

## Contents

- [Why](#why)
- [Quick start](#quick-start)
- [Building](#building)
- [The command-line tool](#the-command-line-tool)
- [Grammar files](#grammar-files)
- [Lexer rules](#lexer-rules)
- [Parser rules](#parser-rules)
- [Expression rules and precedence](#expression-rules-and-precedence)
- [Indentation](#indentation)
- [How the parser decides](#how-the-parser-decides)
- [The generated code](#the-generated-code)
- [The parse tree](#the-parse-tree)
- [Errors](#errors)
- [Examples](#examples)
- [Design](#design)

## Why

The Java world has the most advanced parser generator, ANTLR 4. Nim has no
such thing. So I let Claude and others generate Lindeboom, which has all the
features I like from ANTLR 4: you specify the grammar apart from the code,
and left recursion stops being a problem, because expression rules keep their
natural shape and precedence climbing handles them.

## Quick start

A grammar for arithmetic expressions, `expr.ldb`:

```antlr
grammar Expr;

// Earlier alternatives bind tighter.
expr   : '-' operand=expr                            # neg
       | <assoc=right> left=expr op='^' right=expr   # pow
       | left=expr op=('*' | '/') right=expr         # mul
       | left=expr op=('+' | '-') right=expr         # add
       | NUMBER                                      # num
       | '(' expr ')'                                # paren
       ;

NUMBER : [0-9]+ ('.' [0-9]+)? ;
WS     : [ \t\r\n]+ -> skip ;
```

Check it, and try it on some input without generating code:

```console
$ lindeboom check expr.ldb
expr.ldb: ok (1 parser rules, 2 lexer rules)
$ echo "1 + 2 * 3 ^ 2" > in.txt
$ lindeboom parse --tree expr.ldb in.txt
add
├── left: num
│   └── NUMBER "1"
├── op: '+'
└── right: mul
    ├── left: num
    │   └── NUMBER "2"
    ├── op: '*'
    └── right: pow
        ├── left: num
        │   └── NUMBER "3"
        ├── op: '^'
        └── right: num
            └── NUMBER "2"
```

Generate the lexer and parser:

```console
$ lindeboom gen expr.ldb
wrote ./expr_lexer.nim
wrote ./expr_parser.nim
```

And use them, `eval.nim`:

```nim
import std/[math, os, strutils]
import ./expr_parser

proc eval(n: Node): float =
  case n.kind
  of nkNum: parseFloat(n.text)
  of nkNeg: -eval(n.operand)
  of nkParen: eval(n[1])
  of nkPow, nkMul, nkAdd:
    let a = eval(n.left)
    let b = eval(n.right)
    case n.op.tok.kind
    of tkCaret: pow(a, b)
    of tkStar: a * b
    of tkSlash: a / b
    of tkPlus: a + b
    of tkMinus: a - b
    else: raiseAssert "not an operator"
  of nkToken, nkError: raiseAssert "not an expression"

let res = parseExpr(commandLineParams().join(" "), filename = "expression")
for d in res.diagnostics: echo d
if res.diagnostics.hasErrors: quit 1
echo eval(res.tree)
```

```console
$ nim c --path:<lindeboom>/src eval.nim
$ ./eval "1 + 2 * 3 ^ 2"
19.0
$ ./eval "1 + * 2"
expression:1:5: error: expected '-', '(' or NUMBER but found '*'
```

## Building

Lindeboom needs Nim 2.2.10 or later and nothing else.

```sh
nimble build        # builds bin/lindeboom, regenerating the parsers from the grammars
nimble test         # runs the test suite
```

Generated lexers and parsers are not checked in. `nimble build` and
`nimble test` write them from the grammars; the only exception is the
self-hosted `.ldb` front end, which is checked in so a clean checkout can
bootstrap the generator.

The generated modules import the runtime as `lindeboom/runtime/...`, so
compile them with Lindeboom's `src` directory on the path
(`--path:<lindeboom>/src`), or generate them with `--standalone`, which
copies the runtime next to them.

## The command-line tool

```text
lindeboom check <grammar.ldb>            report grammar problems
lindeboom gen [options] <grammar.ldb>    write <name>_lexer.nim and <name>_parser.nim
lindeboom parse [options] <grammar.ldb> <input>
                                         parse input without generating code
```

| Option | Command | |
|---|---|---|
| `-o`, `--out <dir>` | `gen` | output directory; default: the grammar's directory |
| `--standalone` | `gen` | copy the runtime into `<dir>/lindeboom_runtime` and import it from there |
| `-r`, `--rule <name>` | `parse` | start rule; default: the first parser rule |
| `--tree` | `parse` | print the parse tree |
| `--tokens` | `parse` | print the tokens instead of parsing |
| `-h`, `--help` | | show the help |
| `-v`, `--version` | | show the version |

All commands report grammar errors and warnings as
`file:line:col: severity: message`. The exit code is 0 on success, 1 when
the grammar or the input has errors, and 2 for usage errors and files that
cannot be read or written.

`parse` runs the grammar through an interpreter that builds the same tree
and reports the same errors as the generated parser, so a grammar can be
developed without compiling anything.

## Grammar files

A grammar file starts with `grammar Name;`, followed in any order by rules
and these sections:

```antlr
options { tabWidth = 4; }          // the only option; see Indentation
tokens { INDENT, DEDENT }          // tokens without a lexer rule
indentation { ... }                // see Indentation
```

Rules whose name starts with an uppercase letter are lexer rules; the
others are parser rules. Comments are `// ...` and `/* ... */`.

The format is ANTLR 4's, without what needs target-language code, and
with the `indentation` block added. Not supported: actions and semantic
predicates, lexer modes (`mode`, `pushMode`, `popMode`), grammar imports
and `lexer grammar` / `parser grammar` files, rule arguments and return
values, `options` other than `tabWidth`, channels other than `HIDDEN`, and
indirect left recursion. Those are syntax errors or are reported by
`check`.

## Lexer rules

```antlr
ID       : [a-zA-Z_] [a-zA-Z0-9_]* ;
STRING   : '"' (~["\\\r\n] | '\\' .)* '"' ;
COMMENT  : '/*' .*? '*/' -> skip ;
LINE     : '//' ~[\n]* -> channel(HIDDEN) ;
fragment DIGIT : [0-9] ;
```

| Syntax | Matches |
|---|---|
| `'if'` | the text; escapes `\n \r \t \b \f \\ \' \"`, `é`, `\u{1F600}` |
| `'a'..'z'` | one character in the range |
| `[a-z_]` | one character in the set; also `\]`, `\[` and `\-` |
| `.` | any one character |
| `~x` | any one character not matched by `x`, which is a character, range, set or a choice of those |
| `x y`, `x \| y`, `( ... )` | sequence, choice, grouping |
| `x?`, `x*`, `x+` | optional, repeated |
| `x??`, `x*?`, `x+?` | the same, non-greedy: `'/*' .*? '*/'` stops at the first `*/` |
| `NAME` | another lexer rule, inlined |

A `fragment` rule makes no token of its own; other lexer rules use it.
Lexer rules cannot refer to themselves, directly or through others.

After `->`, commands say what happens to the match: `skip` drops it,
`channel(HIDDEN)` makes a hidden token, which the parser ignores, and
`type(NAME)` gives it the kind of another token.

The input is matched by **longest match**; between tokens that match the
same length, literals used in parser rules come first, then lexer rules in
the order of the file. `check` warns about a token that can never be
produced because another always takes priority. Input that no rule matches
is an error, and is skipped.

Literals in parser rules (`'if'`, `'+'`) are tokens too, without a lexer
rule. A lexer rule that is only that literal (`IF : 'if' ;`) is the same
token.

## Parser rules

```antlr
file   : stmt* EOF ;
stmt   : 'let' name=ID '=' value=expr ';'             # let
       | 'print' args=expr (',' args=expr)* ';'      # print
       ;
```

Elements are rule references (`expr`), token references (`ID`, `EOF`),
literals (`'let'`), `.` for any token, and `~x` for any token except
those in `x`, a token or a choice of tokens (`~(';' | '}')`). They are
combined as in lexer rules: sequence, `|`, `( ... )`, `?`, `*` and `+`
(greedy only). An alternative may be empty.

**Labels.** `name=x` gives an element a name in the tree, and the
generated parser an accessor: `n.name`. A label on a block names the
elements in it: `op=('+' | '-')`. Where a label can name more than one son
of a node, because it is used twice or in a loop, its accessor returns all
of them, as a `seq`. ANTLR's `+=` is written as plain `=`:
`args=expr (',' args=expr)*`.

A label cannot be one of the names of the tree API (`kind`, `edge`, `tok`,
`sons`, `len`, `text`, `pos`, `items`, `treeRepr`). A label that is a Nim
keyword is fine; its accessor is used with backticks: ``n.`type` ``.
A label that is not a Nim identifier, or that Nim would take for another
label or a name of the tree API, gets an accessor that is: `id_` gives
`n.id`, and of `b1` and `b_1` the second gives `n.b_12`.
Lexer rules cannot have labels.

**Alternative labels.** `# name` after an alternative gives its nodes their
own kind, `nkName`; without them, a rule's nodes have the kind `nkRule`.
Either all alternatives of a rule are labelled or none are. Rules can
share an alternative label, and then share the node kind.

Every parser rule can be a start rule. The input must end after it, whether
the rule ends with `EOF` or not.

## Expression rules and precedence

A rule with alternatives that start with the rule itself is an expression
rule, parsed by precedence climbing as in ANTLR 4. Its alternatives come in
four shapes:

```antlr
e : '-' e                 // prefix
  | e '(' args? ')'       // suffix
  | e '*' e               // binary
  | ID                    // primary
  | '(' e ')'             // primary: e is not first
  ;
```

Earlier alternatives bind tighter, whatever their shape. Binary operators
are left-associative; `<assoc=right>` at the start of an alternative makes
it right-associative: `<assoc=right> e '^' e`. There are no
non-associative operators.

The rule needs at least one alternative that does not start with itself,
must not match empty input, and an alternative that starts with itself
must match something after it. Left recursion through another rule
(`a : b 'x' ; b : a 'y' | 'z' ;`) is an error.

In the tree, an operator alternative's node has the left operand as its
first son, labels included, as in the quick start.

## Indentation

```antlr
grammar MiniPy;

options { tabWidth = 8; }
tokens { INDENT, DEDENT }

indentation {
  newline  = NL;
  indent   = INDENT;
  dedent   = DEDENT;
  brackets = '(' ')', '[' ']';
  tabs     = expand;
}

block : NL INDENT stmt+ DEDENT ;
NL    : '\r'? '\n' ;
WS    : [ \t]+ -> skip ;
```

`newline` names the lexer rule for line breaks; `indent` and `dedent` name
tokens declared in `tokens { }`. Between the lexer and the parser, a
filter then:

- drops newlines inside the `brackets` (pairs of literals used in parser
  rules) and on lines without other tokens, including lines with only
  skipped or hidden tokens, such as comments;
- adds an `INDENT` before the first token of a line indented further than
  the line before, and a `DEDENT` for each indentation level a line closes;
- at the end of the input, adds a newline if the last line has none, and
  the `DEDENT`s for the levels still open.

A line that dedents to a level that was never opened is an error. `tabs`
says how tabs in indentation count:

| `tabs` | |
|---|---|
| `expand` (default) | a tab moves to the next multiple of `tabWidth` (default 8) |
| `strict` | as `expand`, but an error where the result would depend on `tabWidth` |
| `error` | tabs in indentation are an error |

## How the parser decides

The parser uses one token when that settles a choice. Otherwise it predicts
with an ATN built from the grammar, following alternatives in parallel through
the remaining input and the active rule-call context. It then parses the
selected alternative once. Lookahead worked out without the call context is
cached and reused; lookahead that needs the context is worked out again each
time, so the cache does not grow with the input. This is the ALL(\*) algorithm from [Parr, Harwell, and Fisher,
"Adaptive LL(\*) Parsing: The Power of Dynamic Analysis" (OOPSLA 2014)](https://www.antlr.org/papers/allstar-techreport.pdf), that also powers ANTLR 4.
Ambiguous input is resolved in favor of the earliest alternative.
Expression rules continue to use precedence climbing.

As in ANTLR, a prediction first looks only at the rules it can see from the
choice, and uses the active call context only when that leaves more than one
alternative. Without the context a prediction can settle a choice before the
input fails to match it, so input with a syntax error is parsed a second
time with the call context in every prediction. Errors and recovery are
those of the second parse.

Where prediction differs from ANTLR 4, it gives the same parse of valid
input and aims to do better:

- ANTLR's default reports errors from the first look, which can differ from
  what the call context would have found; the two-stage parse is something
  an ANTLR user sets up by hand.
- A failed prediction reports the tokens that could have come next at the
  farthest token it read, instead of "no viable alternative".
- The first look hands a choice to the call context only when no more
  lookahead can separate the alternatives, where ANTLR does so at the first
  sign of a conflict. Lookahead without the context is cached and shared by
  every call site.

## The generated code

`lindeboom gen grammar.ldb` writes two modules, named after the grammar
(`grammar CalcVar;` gives `calcVar_lexer.nim` and `calcVar_parser.nim`).

The lexer module has:

- `TokenKind`, an enum: `tkEOF` first, then the literals of the parser
  rules (`tkIf` for `'if'`, `tkPlus` for `'+'`, `tkLParen` for `'('`), the
  lexer rules (`tkID` for `ID`) and the tokens of `tokens { }`. Each
  value's string is its name in the grammar: `$tkPlus == "'+'"`.
- `Token`, a `LexerToken[TokenKind]` with `kind`, `start` and `stop`
  (byte offsets, `stop` exclusive), `pos` and `hidden`; `t.text(src)` is
  its text.
- `tokenize(src, d)`, the tokens of `src` ending with `tkEOF`, with errors
  added to the `Diagnostics` `d`.

The parser module exports the lexer module and the runtime, and has:

- `NodeKind`: `nkToken`, `nkError`, then a kind per alternative label or
  unlabelled rule;
- `NodeLabel`: `lbNone`, then a value per label;
- `Node`, the tree node type, and an accessor per label;
- for every parser rule, `parseRule(src, filename = "input", formatter =
  nil): ParseResult[Node]`, which tokenizes and parses `src`. The result
  has the `tree` and the `diagnostics`. There is a tree even after syntax
  errors.

## The parse tree

There is one node type, `Node`, in the style of the Nim compiler's
`PNode`. A node made by a rule has the kind of its alternative and the
nodes it matched as `sons`, in input order. A token is a node of kind
`nkToken` with the token as `tok`. Hidden tokens are not in the tree; nor
is `EOF`.

| | |
|---|---|
| `n.kind` | the node kind |
| `n.sons`, `n.len`, `n[i]`, `for x in n` | the sons |
| `n.tok` | the token, for an `nkToken` node |
| `n.edge` | the label of `n` in its parent, `lbNone` if none |
| `n.text` | the source text from the first to the last token of `n` |
| `n.pos` | the position (`line`, `col`, 1-based) of the first token of `n` |
| `n.name` (a label) | the son with that label, or nil; a `seq` for a label that can name several |
| `n.son(lbName)`, `n.sonsWith(lbName)` | the same, by label value |
| `n.token(tkKind)` | the first son that is a token of that kind, or nil |
| `n.has(tkKind)` | whether there is one; for flags such as `'virtual'?` |
| `n.treeRepr` | the tree as text, as `lindeboom parse --tree` prints it |

Unlabelled sons are reached by position (`n[1]` for the `expr` in
`'(' expr ')'`) or by kind. `token` and `has` look at the sons of `n` only,
not deeper.

After a syntax error, the tree has `nkError` nodes holding the tokens that
were skipped, and nodes can lack sons they normally have, so accessors can
return nil. A program that walks only trees without errors does not need
to handle that.

## Errors

**Grammar problems** are reported by `check`, `gen` and `parse` with their
position in the grammar. Errors stop code generation; warnings about unused
tokens or rules and tokens that never match do not.

**Syntax errors** in the input come back in `ParseResult.diagnostics`.
Iterating over the `Diagnostics` gives them in source order; `$d` is
`file:line:col: error: message`, and `hasErrors` and `errorCount` say if
there were any. The default message says what could have come there and
what was found:

```text
input:1:5: error: expected '-', '(' or NUMBER but found '*'
input:1:3: error: expected '=' or ';' but found ID 'b'
```

The parser recovers as ANTLR does: the rule that has the error skips
tokens until one that can follow a rule being parsed and returns what it
has so far; a loop facing a token that can neither continue nor end it
skips tokens until one that can. No new error is reported until a token
has been matched, so one mistake gives one message.

Each syntax error is also kept as data: `d.syntax` is a
`SyntaxErrorInfo` with

| | |
|---|---|
| `pos` | where the error is |
| `msg` | the default message |
| `hasToken` | false for a lexer error, which has no token |
| `found`, `text` | the kind and text of the token found (`e.foundKind` gives the `TokenKind`) |
| `expected` | the kinds that could have come there, `EOF` last (`e.expectedKinds`) |
| `rules` | the names of the rules being parsed, outermost first |

To word the messages yourself, pass a formatter, as with ANTLR's error
listeners:

```nim
proc words(e: SyntaxErrorInfo): string =
  if not e.hasToken: return "cannot read " & e.text
  var names: seq[string]
  for k in e.expectedKinds: names.add(if k == tkNUMBER: "a number" else: $k)
  "wanted " & names.join(" or ") & ", got " & e.text.escape

let res = parseCalc(src, formatter = words)
```

The formatter words every syntax error, lexer errors included.

## Examples

In `examples/`:

- `calc`: a floating-point calculator with one rule per precedence level;
- `calc_var`: an integer calculator with variables and an interactive
  shell, with an expression rule;
- `json`: a JSON pretty-printer;
- `lua`: the full Lua 5.4 grammar (parser only), with long brackets,
  short-string escapes, and all twelve expression precedence levels;
- `miniml`: an eager, statically typed functional language with a type
  checker, interpreter, and REPL, after plzoo's MiniML;
- `minipy`: the grammar of a small Python-like language, with indentation.

Lindeboom's own grammar front end is generated from
`src/lindeboom/grammar/ldb.ldb`. Planned work is in [`issues/`](issues/README.md).

## Design

```text
.ldb ─▶ parse grammar ─▶ checks + analysis ─▶ codegen ─▶ foo_lexer.nim, foo_parser.nim

At runtime:
source ─▶ lexer ─▶ indentation filter ─▶ parser ─▶ parse tree
```

- **Lexer:** a DFA over UTF-8 bytes, built from the lexer rules and
  stored as tables. Fast, and needs no hand-written code.
- **Indentation:** a separate filter between the lexer and the parser, so
  one well-tested algorithm serves every indentation grammar.
- **Parser:** recursive descent, one procedure per rule. Non-LL(1) choices use
  adaptive ATN prediction with cached lookahead and the active call context.
  Expression rules use precedence climbing.
- **Output:** a generic parse tree processed with `case n.kind`, as in the
  Nim compiler, rather than a type per rule.
- **Syntax errors:** recovered from as in ANTLR, and kept as data as well
  as a message; the grammar has no say in the wording, the program does.
- **Interpreter:** `lindeboom parse` runs the analysed grammar directly,
  and the tests check that it agrees with the generated parsers.
