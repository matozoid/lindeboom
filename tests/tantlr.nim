## Prediction tests ported from the descriptors of ANTLR 4's runtime test
## suite (runtime-testsuite/resources/org/antlr/v4/test/runtime/descriptors).
## Actions and diagnostics are replaced by parse tree expectations. Each
## grammar runs in the interpreter and as a generated parser. The ones below
## are written out here; the converted files in `tests/antlr` are described
## in its README.
##
## Left out, because they need what Lindeboom does not support:
##
## - FullContextParsing: ExprAmbiguity_1 and _2 (rule arguments and
##   predicates on them; LeftRecursion covers the same expressions), and
##   FullContextIF_THEN_ELSEParse_6, the same as _5.
## - LeftRecursion: SemPredFailOption (a predicate that fails).
## - ParserExec: BuildParseTree_FALSE (there is no mode without a tree),
##   IfIfElseNonGreedyBinding1 and _2 (non-greedy `??`), ParserProperty and
##   PredicatedIfIfElse (semantic predicates, issue 22), and
##   PredictionMode_SLL (there is no SLL-only mode; the full-context fallback
##   gives PredictionMode_LL's tree).
## - ParseTrees: AltNum (`contextSuperClass` and alternative numbers),
##   ExtraToken, ExtraTokensAndAltLabels, NoViableAlt and Sync (trees after
##   error recovery, which differs from ANTLR's), and
##   TokenAndRuleContextString (prints the rule invocation stack).

import std/[algorithm, assertions, os, strutils, tables]
from std/unicode import runeLen
import lindeboom/[grammar, lexgen, parsegen]
import ./[codegenhelpers, parsehelpers]

type Descriptor = object
  name, grammar: string
  inputs: seq[(string, string)] ## input and the expected tree

const
  idWs = "ID : [a-z]+ ;\nWS : [ \\t\\n]+ -> skip ;\n"
  idIntWs = "ID : [a-z]+ ;\nINT : [0-9]+ ;\n" &
    "WS : [ \\t\\n]+ -> skip ;\n"

let descriptors = [
  Descriptor(name: "FullContextParsing_AmbiguityNoLoop", grammar: """
grammar T;
prog : expr expr | expr ;
expr : '@' | ID '@' | ID ;
ID : [a-z]+ ;
WS : [ \r\n\t]+ -> skip ;
""", inputs: @[("a@", """
prog
├── expr
│   └── ID "a"
└── expr
    └── '@'
""")]),
  Descriptor(name: "FullContextParsing_CtxSensitiveDFA", grammar: """
grammar T;
s : '$' a | '@' b ;
a : e ID ;
b : e INT ID ;
e : INT | ;
""" & idIntWs, inputs: @[("$ 34 abc", """
s
├── '$'
└── a
    ├── e
    │   └── INT "34"
    └── ID "abc"
"""), ("@ 34 abc", """
s
├── '@'
└── b
    ├── e
    ├── INT "34"
    └── ID "abc"
""")]),
  Descriptor(name: "FullContextParsing_SLLSeesEOFInLLGrammar", grammar: """
grammar T;
s : a ;
a : e ID ;
b : e INT ID ;
e : INT | ;
""" & idIntWs, inputs: @[("34 abc", """
s
└── a
    ├── e
    │   └── INT "34"
    └── ID "abc"
""")]),
  Descriptor(name: "FullContextParsing_IfThenElse", grammar: """
grammar T;
s : '{' stat* '}' ;
stat : 'if' ID 'then' stat ('else' ID)? | 'return' ;
""" & idWs, inputs: @[("{ if x then return }", """
s
├── '{'
├── stat
│   ├── 'if'
│   ├── ID "x"
│   ├── 'then'
│   └── stat
│       └── 'return'
└── '}'
"""), ("{ if x then return else foo }", """
s
├── '{'
├── stat
│   ├── 'if'
│   ├── ID "x"
│   ├── 'then'
│   ├── stat
│   │   └── 'return'
│   ├── 'else'
│   └── ID "foo"
└── '}'
"""), ("{ if x then if y then return else foo }", """
s
├── '{'
├── stat
│   ├── 'if'
│   ├── ID "x"
│   ├── 'then'
│   └── stat
│       ├── 'if'
│       ├── ID "y"
│       ├── 'then'
│       ├── stat
│       │   └── 'return'
│       ├── 'else'
│       └── ID "foo"
└── '}'
""")]),
  Descriptor(name: "FullContextParsing_LoopsSimulateTailRecursion", grammar: """
grammar T;
prog : expr_or_assign* ;
expr_or_assign : expr '++' | expr ;
expr : expr_primary ('<-' ID)? ;
expr_primary : '(' ID ')' | ID '(' ID ')' | ID ;
ID : [a-z]+ ;
""", inputs: @[("a(i)<-x", """
prog
└── expr_or_assign
    └── expr
        ├── expr_primary
        │   ├── ID "a"
        │   ├── '('
        │   ├── ID "i"
        │   └── ')'
        ├── '<-'
        └── ID "x"
""")]),
  Descriptor(name: "LeftRecursion_PrecedenceFilterConsidersContext", grammar: """
grammar T;
prog : statement* EOF ;
statement : letterA | statement letterA 'b' ;
letterA : 'a' ;
""", inputs: @[("aa", """
prog
├── statement
│   └── letterA
│       └── 'a'
└── statement
    └── letterA
        └── 'a'
""")]),
  Descriptor(name: "ParserExec_PredictionIssue334", grammar: """
grammar T;
file_ : item (SEMICOLON item)* SEMICOLON? EOF ;
item : A B? ;
SEMICOLON : ';' ;
A : 'a' | 'A' ;
B : 'b' | 'B' ;
WS : [ \r\t\n]+ -> skip ;
""", inputs: @[("a", """
file_
└── item
    └── A "a"
"""), ("a;b", """
input:1:3: error: expected A or end of input but found B 'b'
file_
├── item
│   └── A "a"
└── error
    ├── SEMICOLON ";"
    └── B "b"
""")]),
  Descriptor(name: "ParserExec_AorAPlus", grammar: "grammar T;\na : (ID|ID)+ ;\n" &
    idWs, inputs: @[("a b c", """
a
├── ID "a"
├── ID "b"
└── ID "c"
""")]),
  Descriptor(name: "ParserExec_IfIfElseGreedyBinding", grammar: """
grammar T;
start : statement+ ;
statement : 'x' | ifStatement ;
ifStatement : 'if' 'y' statement ('else' statement|) ;
""" & "WS : [ \\t\\n]+ -> skip ;\n", inputs: @[("if y if y x else x", """
start
└── statement
    └── ifStatement
        ├── 'if'
        ├── 'y'
        └── statement
            └── ifStatement
                ├── 'if'
                ├── 'y'
                ├── statement
                │   └── 'x'
                ├── 'else'
                └── statement
                    └── 'x'
""")])]

let tmp = getTempDir() / "lindeboom_tantlr"

for d in descriptors:
  block interpreter:
    # Full-context prediction alone must parse as SLL first does.
    let (a, t, diag) = analyzed(d.grammar)
    doAssert not diag.hasErrors, d.name & ": " & $diag.items
    let ll = a.fullContextOnly
    for (input, expected) in d.inputs:
      let got = interpreted(a, t, input)
      doAssert got == expected, d.name & " " & input.escape & ":\n" & got
      let llGot = interpreted(ll, t, input)
      doAssert llGot == got, d.name & " " & input.escape & " in full LL:\n" & llGot

block generated_parsers_match:
  for d in descriptors:
    let dir = tmp / d.name
    createDir(dir)
    let grammarFile = dir / "t.ldb"
    writeFile(grammarFile, d.grammar)
    var inputs: seq[string]
    for (input, _) in d.inputs: inputs.add input
    let c = Case(grammarFile: grammarFile, inputs: inputs)
    discard generate(c, dir, standalone = false)
    let got = runDriver(compile(dir, standalone = false), dir, inputs)
    for i, (input, expected) in d.inputs:
      doAssert got[i] == expected, d.name & " " & input.escape & ":\n" & got[i]

# ---- descriptors converted from ANTLR's files, in tests/antlr ----

type Converted = object
  name, grammar: string
  inputs: seq[(string, string)] ## input and the expected tree, "" for none

proc readConverted(file: string): (string, string, string) =
  ## The grammar, input and expected tree (ANTLR's `toStringTree` without
  ## `<EOF>`) of a converted descriptor.
  var sections = initTable[string, string]()
  var name = ""
  for line in readFile(file).splitLines:
    if line.len > 2 and line[0] == '[' and line[^1] == ']':
      name = line[1 .. ^2]
      sections[name] = ""
    elif name.len > 0:
      sections[name].add line & "\n"
  (sections["grammar"].strip & "\n", sections["input"].strip.unescape,
    sections.getOrDefault("tree").strip)

proc lispTree(repr: string): string =
  ## A tree printed by `treeRepr` in the form of ANTLR's `toStringTree`.
  type Item = tuple[text: string, sons: seq[string]]
  var stack: seq[Item]
  proc close(stack: var seq[Item]) =
    let x = stack.pop
    let s = if x.sons.len == 0: x.text else: "(" & x.text & " " & x.sons.join(" ") & ")"
    if stack.len > 0: stack[^1].sons.add s
    else: stack.add (s, @[])
  for line in repr.splitLines:
    if line.len == 0: continue
    let at = line.rfind("── ")
    let start = if at < 0: 0 else: at + "── ".len
    let depth = line[0 ..< start].runeLen div 4
    var text = line[start .. ^1]
    let colon = text.find(": ")
    if colon > 0 and text[0 ..< colon].validIdentifier: text = text[colon + 2 .. ^1]
    if text.startsWith('\''):
      text = text[1 .. ^2].replace("\\'", "'").replace("\\\\", "\\")
    elif text[0].isUpperAscii:
      let space = text.find(' ')
      text = if space < 0: "" else: text[space + 1 .. ^1].unescape
    while stack.len > depth: stack.close
    stack.add (text, @[])
  while stack.len > 1: stack.close
  stack.close
  stack[0].text

proc converted(): seq[Converted] =
  ## The converted descriptors, one per grammar, in file name order.
  var files: seq[string]
  for group in walkDirs(currentSourcePath().parentDir / "antlr" / "*"):
    for f in walkFiles(group / "*.txt"): files.add f
  files.sort
  for f in files:
    let (grammar, input, tree) = readConverted(f)
    let name = f.parentDir.extractFilename & "_" & f.splitFile.name
    var i = 0
    while i < result.len and result[i].grammar != grammar: inc i
    if i == result.len: result.add Converted(name: name, grammar: grammar)
    result[i].inputs.add (input, tree)

var failures: seq[string]

proc checkConverted(c: Converted, input, expected, got: string) =
  ## `got` is what the driver prints: diagnostics, then the tree.
  if got.contains("error:"):
    failures.add c.name & " " & input.escape & ":\n" & got
  elif expected.len > 0 and lispTree(got) != expected:
    failures.add c.name & " " & input.escape & ":\n" & got & "\n" &
      lispTree(got) & "\nexpected " & expected

let convertedCases = converted()

block converted_interpreter:
  for c in convertedCases:
    let (a, t, diag) = analyzed(c.grammar)
    doAssert not diag.hasErrors, c.name & ": " & $diag.items
    let ll = a.fullContextOnly
    for (input, expected) in c.inputs:
      let got = interpreted(a, t, input)
      c.checkConverted(input, expected, got)
      let llGot = interpreted(ll, t, input)
      if llGot != got:
        failures.add c.name & " " & input.escape & " in full LL:\n" & llGot &
          "\nwith SLL first:\n" & got
  doAssert failures.len == 0, "\n\n" & failures.join("\n\n")

block converted_generated_parsers:
  for c in convertedCases:
    let dir = tmp / c.name
    createDir(dir)
    let grammarFile = dir / "t.ldb"
    writeFile(grammarFile, c.grammar)
    var inputs: seq[string]
    for (input, _) in c.inputs: inputs.add input
    discard generate(Case(grammarFile: grammarFile, inputs: inputs), dir,
      standalone = false)
    let got = runDriver(compile(dir, standalone = false), dir, inputs)
    for i, (input, expected) in c.inputs:
      c.checkConverted(input, expected, got[i])
  doAssert failures.len == 0, "\n\n" & failures.join("\n\n")
