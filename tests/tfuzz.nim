## Random input must never crash or hang a parser, interpreted or
## generated, and both must give the same result, as must the interpreter
## predicting in full context only.

import std/[assertions, os, random, strutils]
import lindeboom/[grammar, lexgen, parsegen]
import ./codegenhelpers

let tmp = getTempDir() / "lindeboom_tfuzz"

const inputsPerGrammar = 300

let seeds = [
  Case(grammarFile: root / "tests" / "grammars" / "features.ldb", inputs: @[
    "let a = 1 + (b - -2); list(a, 1 + 2); type t?; raw a 1 ( ; any + ; maybe x;",
    "calc -a ^ b * c() - [d + e]; sum 1 + 2 + 3; ;"]),
  Case(grammarFile: root / "tests" / "grammars" / "ambiguous.ldb", inputs: @[
    "alt a b; alt a 1; alt a; loop a, b, c; plus a . b . c; opt a = b; opt b;",
    "ix a[b]; ix a[b:c][d]; ix a[b[c]:d];"]),
  Case(grammarFile: root / "examples" / "calc" / "calc.ldb", inputs: @[
    "1 + 2 * (3 - 4) / -5"]),
  Case(grammarFile: root / "examples" / "calc_var" / "calc_var.ldb", inputs: @[
    "x = -(y + 2) * 3 / z - 4", "x * -y + 1"]),
  Case(grammarFile: root / "examples" / "json" / "json.ldb", inputs: @[
    "{\"a\": [1, true, null, {}], \"b\": \"\\u00e9\", \"c\": -1.5e3}"]),
  Case(grammarFile: root / "examples" / "minipy" / "minipy.ldb", inputs: @[
    "x = f(1); g(x, -a ** 2 + b[1] * c(d, e))\nreturn x\npass; pass\n",
    "def f(n):\n    if n < 2:\n        return 1\n    else:\n        while n: n = n - 1\n" &
      "    return f(\n  n)\n"]),
  Case(grammarFile: root / "examples" / "miniml" / "miniml.ldb", inputs: @[
    "3 + (if 5 < 6 then 10 else 100) ;; let x = 14 ;;",
    "let fact = fun f (n : int) : int is if n = 0 then 1 else n * f (n-1) ;;" &
      "fact 10 ;;"]),
  Case(grammarFile: root / "examples" / "lua" / "lua.ldb", inputs: @[
    "local x <const> = -a ^ 2 + b * c .. d | e & f << g == h and i or j\n",
    "function T:m(a, ...) for k, v in pairs(a) do a[k] = v end return ... end\n",
    "local s = [==[a ]=] b]==] .. \"x\\z\\n y\" --[[ long ]] ; ::l:: goto l\n"]),
  Case(grammarFile: root / "src" / "lindeboom" / "grammar" / "ldb.ldb", inputs: @[
    readFile(root / "tests" / "grammars" / "features.ldb"),
    readFile(root / "examples" / "minipy" / "minipy.ldb")])]

proc pieces(t: LexerTables, inputs: seq[string]): seq[string] =
  ## The text of every token in `inputs`.
  for input in inputs:
    var d = Diagnostics(filename: "seed")
    for tok in tokenize[int](t, input, d):
      if tok.stop > tok.start: result.add tok.text(input)

proc tokenSoup(r: var Rand, pieces: seq[string]): string =
  ## Up to 30 random tokens.
  for _ in 0 ..< r.rand(30):
    result.add r.sample(pieces)
    result.add r.sample([" ", " ", "", "\n"])

proc mutant(r: var Rand, seed: string): string =
  ## `seed` with a few characters deleted, inserted or duplicated.
  result = seed
  for _ in 0 .. r.rand(3):
    let i = r.rand(result.len)
    case r.rand(2)
    of 0:
      if i < result.len: result.delete(i .. i)
    of 1: result.insert($r.sample(seed & "()[]{},;:=+-*/^.?!\"'#$\n\t"), i)
    else: result.insert(result[i .. min(i + r.rand(8), result.len - 1)], i)

block fuzz_parsers_never_crash_and_agree:
  var r = initRand(20261015)
  for c in seeds:
    let dir = tmp / c.grammarFile.splitFile.name
    let a = generate(c, dir, standalone = false)
    var (g, d) = loadGrammar(readFile(c.grammarFile), c.grammarFile)
    let t = buildLexer(g, a.v, d)
    let ps = pieces(t, c.inputs)
    var inputs: seq[string]
    for i in 0 ..< inputsPerGrammar:
      if i mod 2 == 0: inputs.add r.tokenSoup(ps)
      else: inputs.add r.mutant(r.sample(c.inputs))
    let got = runDriver(compile(dir, standalone = false), dir, inputs)
    let ll = a.fullContextOnly
    for i, input in inputs:
      let expected = interpreted(a, t, input)
      doAssert got[i] == expected, c.grammarFile & " " & input.escape & ":\n" & got[i] &
        "\nexpected:\n" & expected
      let llGot = interpreted(ll, t, input)
      doAssert llGot == expected, c.grammarFile & " " & input.escape &
        " in full LL:\n" & llGot & "\nwith SLL first:\n" & expected

block fuzz_front_end_never_crashes:
  # mutated grammars go through every stage that accepts them
  var r = initRand(20261016)
  let grammars = [readFile(root / "tests" / "grammars" / "features.ldb"),
    readFile(root / "examples" / "minipy" / "minipy.ldb"),
    readFile(root / "src" / "lindeboom" / "grammar" / "ldb.ldb")]
  for _ in 0 ..< 1000:
    var (g, d) = loadGrammar(r.mutant(r.sample(grammars)), "fuzz.ldb")
    if not d.hasErrors:
      let v = buildVocabulary(g)
      let t = buildLexer(g, v, d)
      let a = analyze(g, v, d)
      if not d.hasErrors:
        discard genLexerModule(v, t, "fuzz.ldb")
        discard genParserModule(a, "fuzz.ldb")

removeDir(tmp)
