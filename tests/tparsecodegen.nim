## Generated parsers must compile, also standalone, and agree with the
## interpreter.

import std/[assertions, os, strutils]
import lindeboom/[grammar, lexgen]
import ./codegenhelpers

let tmp = getTempDir() / "lindeboom_tparsecodegen"

let cases = [
  Case(grammarFile: root / "tests" / "grammars" / "features.ldb", inputs: @[
    "", "let a = 1 + (b - -2);", "list(); list(a, 1 + 2);", "type t?; type u;",
    "raw a 1 ( ; any + ; maybe x; maybe; ;", "let a = 1 # comment\n;",
    "let = 1;", "list(a,);", "raw ;", "type t", "let a = 1; $",
    "calc a - b - c * d ^ e ^ f;", "calc -a ^ b * c() - [d + e];", "calc a()();",
    "calc a + ;", "calc a ^;", "sum 1 + 2 + 3;", "sum 1 +;"]),
  Case(grammarFile: root / "examples" / "calc" / "calc.ldb", inputs: @[
    "1 + 2 * (3 - 4)", "-1", "1 +", "(1"]),
  Case(grammarFile: root / "examples" / "json" / "json.ldb", inputs: @[
    "{\"a\": [1, true, null, {}], \"b\": \"\\u00e9\"}", "[]", "{\"a\" 1}", "[1,]"]),
  Case(grammarFile: root / "tests" / "grammars" / "ambiguous.ldb", inputs: @[
    "alt a b; alt a 1; alt a;", "alt a 1 2;", "alt;", "loop a, b, c; loop a;", "loop a, ;",
    "plus a . b . c; plus a;", "opt a = b; opt b;", "opt a =;",
    "ix a[b]; ix a[b:c][d]; ix a[b[c]:d];", "ix a[b:];", "ix a[b c];"]),
  Case(grammarFile: root / "examples" / "minipy" / "minipy.ldb", inputs: @[
    "x = f(1); g(x);\n", "return\n", "x = -a ** 2 + b[1] * c(d, e)\n", "x = \n",
    "f(1)(2) = 3\n", "pass; pass\n",
    "def f(n):\n    if n < 2:\n        return 1\n    elif n:\n        pass\n    else: return [\n" &
      "  n\n]\n\nwhile x: x = x - 1\n", "if x:\n    y\n  z\n", "if x:\ny\n"])]

block parsecodegen_matches_interpreter:
  for c in cases:
    let dir = tmp / c.grammarFile.splitFile.name
    let a = generate(c, dir, standalone = false)
    let got = runDriver(compile(dir, standalone = false), dir, c.inputs)
    var (g, d) = loadGrammar(readFile(c.grammarFile), c.grammarFile)
    let t = buildLexer(g, a.v, d)
    for i, input in c.inputs:
      let expected = interpreted(a, t, input)
      doAssert got[i] == expected, c.grammarFile & " " & input.escape & ":\n" & got[i] &
        "\nexpected:\n" & expected

block parsecodegen_prediction_uses_active_call_context:
  let dir = tmp / "active_call_context"
  let grammarFile = dir / "context.ldb"
  createDir(dir)
  writeFile(grammarFile, "grammar Context;\n" &
    "s : a 'z' ;\na : 'x' | 'x' 'y' ;\nWS : [ ]+ -> skip ;\n")
  let c = Case(grammarFile: grammarFile, inputs: @["x y z", "x z", "x y z"])
  let a = generate(c, dir, standalone = false)
  let got = runDriver(compile(dir, standalone = false), dir, c.inputs)
  var (g, d) = loadGrammar(readFile(grammarFile), grammarFile)
  let t = buildLexer(g, a.v, d)
  for i, input in c.inputs:
    let expected = interpreted(a, t, input)
    doAssert got[i] == expected, got[i] & "\nexpected:\n" & expected

block parsecodegen_prediction_uses_full_context:
  let dir = tmp / "full_context"
  let grammarFile = dir / "context.ldb"
  createDir(dir)
  # The input after `a` distinguishes the alternatives through the caller's
  # continuation: A can be empty or consume `b`.
  writeFile(grammarFile, "grammar FullContext;\n" &
    "s : 'x' b | 'y' c ;\n" &
    "b : a 'a' ;\n" &
    "c : a 'b' 'a' ;\n" &
    "a : 'b' | ;\n" &
    "WS : [ ]+ -> skip ;\n")
  let c = Case(grammarFile: grammarFile, inputs: @[
    "x a", "x b a", "y b a", "y b b a"])
  let a = generate(c, dir, standalone = false)
  let got = runDriver(compile(dir, standalone = false), dir, c.inputs)
  var (g, d) = loadGrammar(readFile(grammarFile), grammarFile)
  let t = buildLexer(g, a.v, d)
  for i, input in c.inputs:
    let expected = interpreted(a, t, input)
    doAssert got[i] == expected, input & ":\n" & got[i] & "\nexpected:\n" & expected

block parsecodegen_dangling_else_uses_nearest_if:
  let dir = tmp / "dangling_else"
  let grammarFile = dir / "dangling.ldb"
  createDir(dir)
  writeFile(grammarFile, "grammar Dangling;\n" &
    "s : stat EOF ;\n" &
    "stat : 'if' ID 'then' stat ('else' stat)? # ifStat\n" &
    "     | ID # atom ;\n" &
    "ID : [a-z]+ ; WS : [ ]+ -> skip ;\n")
  let c = Case(grammarFile: grammarFile, inputs: @[
    "if x then if y then a else b", "if x then if y then a else b else c"])
  let a = generate(c, dir, standalone = false)
  let got = runDriver(compile(dir, standalone = false), dir, c.inputs)
  var (g, d) = loadGrammar(readFile(grammarFile), grammarFile)
  let t = buildLexer(g, a.v, d)
  for i, input in c.inputs:
    let expected = interpreted(a, t, input)
    doAssert got[i] == expected, input & ":\n" & got[i] & "\nexpected:\n" & expected

block parsecodegen_nested_shared_prefix_stress:
  let dir = tmp / "nested_prediction_stress"
  let grammarFile = dir / "nested.ldb"
  createDir(dir)
  writeFile(grammarFile, "grammar NestedPrediction;\n" &
    "s : a EOF ;\n" &
    "a : 'x' a 'y' | 'x' a | 'x' ;\n" &
    "WS : [ ]+ -> skip ;\n")
  var input = ""
  for _ in 0 ..< 18: input.add "x "
  for _ in 0 ..< 17: input.add "y "
  let c = Case(grammarFile: grammarFile, inputs: @[input])
  let a = generate(c, dir, standalone = false)
  let got = runDriver(compile(dir, standalone = false), dir, c.inputs)
  var (g, d) = loadGrammar(readFile(grammarFile), grammarFile)
  let t = buildLexer(g, a.v, d)
  let expected = interpreted(a, t, input)
  doAssert got[0] == expected, got[0] & "\nexpected:\n" & expected

block parsecodegen_paper_stat_grammar:
  let dir = tmp / "paper_stat"
  let grammarFile = dir / "stat.ldb"
  createDir(dir)
  writeFile(grammarFile, "grammar PaperStat;\n" &
    "stat : e '=' e ';' | e ';' ;\n" &
    "e : e '*' e | e '+' e | e '(' e ')' | ID ;\n" &
    "ID : [a-z]+ ; WS : [ ]+ -> skip ;\n")
  let c = Case(grammarFile: grammarFile,
    inputs: @["a+b=c*d;", "a;", "f(a)+b=c;"])
  let a = generate(c, dir, standalone = false)
  let got = runDriver(compile(dir, standalone = false), dir, c.inputs)
  var (g, d) = loadGrammar(readFile(grammarFile), grammarFile)
  let t = buildLexer(g, a.v, d)
  for i, input in c.inputs:
    let expected = interpreted(a, t, input)
    doAssert got[i] == expected, got[i] & "\nexpected:\n" & expected

block parsecodegen_standalone:
  let c = cases[2]
  let dir = tmp / "standalone"
  discard generate(c, dir, standalone = true)
  let got = runDriver(compile(dir, standalone = true), dir, @["[1]"])
  doAssert got == @["json\n└── array\n    ├── '['\n    ├── elements: number\n" &
    "    │   └── NUMBER \"1\"\n    └── ']'\n"], $got

block parsecodegen_formatter:
  # a formatter gets the error data with the generated token kinds
  let dir = tmp / "formatter"
  discard generate(cases[1], dir, standalone = false)
  writeFile(dir / "driver.nim", """
import std/[os, strutils]
import ./calc_parser

proc words(e: SyntaxErrorInfo): string =
  if not e.hasToken: return "cannot read " & e.text
  var names: seq[string]
  for k in e.expectedKinds: names.add(if k == tkNUMBER: "a number" else: $k)
  result = e.rules.join(" > ") & ": wanted " & names.join(" or ") & ", got " &
    $e.foundKind & " " & e.text.escape

for f in commandLineParams():
  for d in parseCalc(readFile(f), formatter = words).diagnostics: echo d.msg
  stdout.write "----\n"
""")
  let got = runDriver(compile(dir, standalone = false), dir, @["1 +", "1 $ 2", "(1"])
  doAssert got == @[
    "calc > expr > term > factor: wanted '-' or '(' or a number, got EOF \"\"\n",
    "cannot read $\ncalc > expr > term: wanted '+' or '-' or '*' or '/' or ')' or EOF, " &
      "got NUMBER \"2\"\n",
    "calc > expr > term > factor: wanted '+' or '-' or '*' or '/' or ')', got EOF \"\"\n"], $got

block parsecodegen_unlabelled_tokens:
  # `has` and `token` find tokens by kind; a `token=` label is an overload
  let dir = tmp / "tokens"
  createDir(dir)
  let grammarFile = dir / "flags.ldb"
  writeFile(grammarFile, "grammar Flags;\ns : 'virtual'? token=ID ';' ;\n" &
    "ID : [a-z]+ ;\nWS : ' ' -> skip ;\n")
  discard generate(Case(grammarFile: grammarFile), dir, standalone = false)
  writeFile(dir / "driver.nim", """
import std/os
import ./flags_parser

for f in commandLineParams():
  let n = parseS(readFile(f)).tree
  echo n.has(tkVirtual), " ", n.token(tkVirtual) != nil, " ", n.token.text
  stdout.write "----\n"
""")
  let got = runDriver(compile(dir, standalone = false), dir, @["virtual f;", "g;"])
  doAssert got == @["true true f\n", "false false g\n"], $got

block parsecodegen_label_accessor_names:
  # Labels that are not Nim identifiers, or that Nim would take for another
  # label or the tree API, get accessors that are.
  let dir = tmp / "accessors"
  createDir(dir)
  let grammarFile = dir / "names.ldb"
  writeFile(grammarFile, "grammar Names;\n" &
    "s : id_=ID a__b=ID b1=ID b_1=ID te_xt=ID ;\n" &
    "ID : [a-z]+ ;\nWS : ' ' -> skip ;\n")
  discard generate(Case(grammarFile: grammarFile), dir, standalone = false)
  writeFile(dir / "driver.nim", """
import std/os
import ./names_parser

for f in commandLineParams():
  let n = parseS(readFile(f)).tree
  echo n.id.text, n.a_b.text, n.b1.text, n.b_12.text, n.te_xt2.text, n.text
  stdout.write "----\n"
""")
  let got = runDriver(compile(dir, standalone = false), dir, @["p q r s t"])
  doAssert got == @["pqrstp q r s t\n"], $got

removeDir(tmp)
