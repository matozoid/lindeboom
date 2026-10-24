import std/[assertions, strutils, tables]
import lindeboom/[grammar, lexgen, parsegen]
import ./parsehelpers

const lexer = """
ID : [a-z]+ ;
INT : [0-9]+ ;
WS : [ \n]+ -> skip ;
"""

proc g(rules: string): string = "grammar G;\n" & rules & "\n" & lexer

proc expectTree(rules, input, expected: string, rule = "") =
  let got = tree(g(rules), input, rule)
  doAssert got == expected.dedent, "\n" & got

proc expectError(rules, input, expected: string, rule = "") =
  let got = tree(g(rules), input, rule)
  doAssert got == expected, got

proc expectProblem(rules, expected: string) =
  let got = problems(g(rules))
  var found = false
  for m in got:
    if expected in m: found = true
  doAssert found, $got

block parsegen_sequence_and_labels:
  expectTree("s : 'let' name=ID '=' value=INT ;", "let x = 1", """
    s
    ├── 'let'
    ├── name: ID "x"
    ├── '='
    └── value: INT "1"
    """)

block parsegen_rule_refs_and_alt_labels:
  expectTree("s : a a ;\na : ID # name | INT # int ;", "x 1", """
    s
    ├── name
    │   └── ID "x"
    └── int
        └── INT "1"
    """)

block parsegen_ebnf:
  let rules = "s : 'a'? ID* ('b' INT)+ ;"
  expectTree(rules, "b 1", """
    s
    ├── 'b'
    └── INT "1"
    """)
  expectTree(rules, "a x y b 1 b 2", """
    s
    ├── 'a'
    ├── ID "x"
    ├── ID "y"
    ├── 'b'
    ├── INT "1"
    ├── 'b'
    └── INT "2"
    """)
  expectError(rules, "a x", "1:4: expected 'b' or ID but found end of input")

block parsegen_nested_alternatives:
  let rules = "s : ('a' ID | 'b' INT | ) ';' ;"
  expectTree(rules, "b 2;", """
    s
    ├── 'b'
    ├── INT "2"
    └── ';'
    """)
  expectTree(rules, ";", """
    s
    └── ';'
    """)
  expectError(rules, "x", "1:1: expected 'a', 'b' or ';' but found ID 'x'")

block parsegen_token_sets:
  expectTree("s : op=('+' | '-') ~';' . ';' ;", "+ x 1;", """
    s
    ├── op: '+'
    ├── ID "x"
    ├── INT "1"
    └── ';'
    """)
  expectError("s : op=('+' | '-') ;", "x", "1:1: expected '+' or '-' but found ID 'x'")
  expectError("s : ~ID ;", "x", "1:1: expected INT but found ID 'x'")

block parsegen_list_labels:
  expectTree("s : xs=ID (',' xs=ID)* ;", "a, b", """
    s
    ├── xs: ID "a"
    ├── ','
    └── xs: ID "b"
    """)

proc listLabels(rules: string): seq[string] =
  let (a, _, _) = analyzed(g(rules))
  for k, name in a.labels:
    if a.labelIsList[k]: result.add name

block parsegen_list_labels_are_inferred:
  doAssert listLabels("s : x=ID y=INT? ;") == @[]
  doAssert listLabels("s : x=ID | x=INT ;") == @[]
  doAssert listLabels("s : (x=ID | x=INT) ';' ;") == @[]
  doAssert listLabels("s : x=ID x=INT ;") == @["x"]
  doAssert listLabels("s : x=ID (',' y=ID)* ;") == @["y"]
  doAssert listLabels("s : (x=ID)+ ;") == @["x"]
  doAssert listLabels("s : x=(ID INT) y=(ID | INT) ;") == @["x"]
  doAssert listLabels("s : x=ID? x=INT? ;") == @["x"]
  # one accessor per name, so a list in one rule is a list in all
  doAssert listLabels("s : x=ID t ;\nt : x=INT* ;") == @["x"]
  # a label inside a labelled block takes precedence
  doAssert listLabels("s : x=(y=ID INT) ;") == @[]

block parsegen_label_on_block:
  expectTree("s : x=(ID | INT) y=(ID INT) ;", "1 a 2", """
    s
    ├── x: INT "1"
    ├── y: ID "a"
    └── y: INT "2"
    """)

block parsegen_empty_rule:
  expectTree("s : 'a' e 'b' ;\ne : ;", "a b", """
    s
    ├── 'a'
    ├── e
    └── 'b'
    """)

block parsegen_nullable_alternative_uses_follow:
  # `e` can be empty, so 'b' after it selects the empty alternative
  expectTree("s : e 'b' ;\ne : 'a' | ;", "b", """
    s
    ├── e
    └── 'b'
    """)

block parsegen_eof:
  expectTree("s : ID EOF ;", "x", """
    s
    └── ID "x"
    """)
  expectError("s : ID ;", "x y", "1:3: expected end of input but found ID 'y'")
  expectError("s : ID ID ;", "x", "1:2: expected ID but found end of input")

block parsegen_any_rule_is_a_start_rule:
  let rules = "s : 'let' e ;\ne : ID | INT ;"
  expectTree(rules, "42", """
    e
    └── INT "42"
    """, rule = "e")
  expectError(rules, "42", "1:1: expected 'let' but found INT '42'")

block parsegen_lexer_error:
  expectError("s : ID ;", "x$", "1:2: unexpected character '$'")

block parsegen_hidden_tokens_are_ignored:
  let src = "grammar G;\ns : ID ID ;\nID : [a-z]+ ;\nC : '#' [a-z]* -> channel(HIDDEN) ;\nWS : ' '+ -> skip ;\n"
  doAssert tree(src, "a #c b") == "s\n├── ID \"a\"\n└── ID \"b\"\n", tree(src, "a #c b")

block parsegen_tree_text_escapes:
  let src = "grammar G;\ns : S ;\nS : '\"' ~'\"'* '\"' ;\n"
  doAssert tree(src, "\"a\nb\"") == "s\n└── S \"\\\"a\\nb\\\"\"\n"

block parsegen_conflicts_are_predicted_without_warnings:
  for rules in [
      "s : ID INT | ID ID ;",
      "s : ('a' | 'a' ID) ;",
      "s : e 'a' ;\ne : 'a' | ;",
      "s : (',' ID)* ','? ;",
      "s : ID? ID ;",
      "s : (ID | INT)? (ID | INT) ;"]:
    doAssert problems(g(rules)).len == 0, $problems(g(rules))

block parsegen_adaptive_alternatives:
  let rules = "s : x=ID '=' INT # assign | ID # name | ID ID # pair ;"
  expectTree(rules, "a = 1", """
    assign
    ├── x: ID "a"
    ├── '='
    └── INT "1"
    """)
  expectTree(rules, "a", """
    name
    └── ID "a"
    """)
  # The caller's continuation distinguishes the longer alternative.
  expectTree(rules, "a b", """
    pair
    ├── ID "a"
    └── ID "b"
    """)
  expectTree("s : a 'z' ;\na : 'x' | 'x' 'y' ;", "x y z", """
    s
    ├── a
    │   ├── 'x'
    │   └── 'y'
    └── 'z'
    """)
  # nested blocks, and sons of the failed attempt are dropped
  expectTree("s : 'a' (ID INT | ID ID) ;", "a x y", """
    s
    ├── 'a'
    ├── ID "x"
    └── ID "y"
    """)
  expectTree("s : 'a' # first | 'a' # second ;", "a", """
    first
    └── 'a'
    """)
  let stackSensitive =
    "s : 'x' b | 'y' c ;\nb : a 'a' ;\nc : a 'b' 'a' ;\na : 'b' | ;"
  expectTree(stackSensitive, "y b a", """
    s
    ├── 'y'
    └── c
        ├── a
        ├── 'b'
        └── 'a'
    """)
  expectTree(stackSensitive, "y b b a", """
    s
    ├── 'y'
    └── c
        ├── a
        │   └── 'b'
        ├── 'b'
        └── 'a'
    """)

  # Figure 1 of Parr, Harwell and Fisher: both statement alternatives begin
  # with an expression, so prediction must consider the caller continuation.
  let stat = "stat : e '=' e ';' | e ';' ;\n" &
    "e : e '*' e | e '+' e | e '(' e ')' | ID ;"
  expectTree(stat, "a+b=c*d;", """
    stat
    ├── e
    │   ├── e
    │   │   └── ID "a"
    │   ├── '+'
    │   └── e
    │       └── ID "b"
    ├── '='
    ├── e
    │   ├── e
    │   │   └── ID "c"
    │   ├── '*'
    │   └── e
    │       └── ID "d"
    └── ';'
    """)

block parsegen_dangling_else_uses_nearest_if:
  let rules = "s : stat EOF ;\n" &
    "stat : 'if' ID 'then' stat ('else' stat)? # ifStat\n" &
    "     | ID # atom ;"
  expectTree(rules, "if x then if y then a else b", """
    s
    └── ifStat
        ├── 'if'
        ├── ID "x"
        ├── 'then'
        └── ifStat
            ├── 'if'
            ├── ID "y"
            ├── 'then'
            ├── atom
            │   └── ID "a"
            ├── 'else'
            └── atom
                └── ID "b"
    """)

block parsegen_stack_sensitive_prediction:
  # Paper, section 2: A's choice depends on the rule that called it.
  let rules = "s : 'x' b | 'y' c ;\nb : a 'a' ;\nc : a 'b' 'a' ;\n" &
    "a : 'b' | ;"
  for input in ["x b a", "x a", "y b b a", "y b a"]:
    let got = tree(g(rules), input)
    doAssert "syntax" notin got and "error" notin got, input & "\n" & got

block parsegen_ambiguity_takes_lowest_alternative:
  expectTree("s : ID # first | ID # second ;", "a", """
    first
    └── ID "a"
    """)

block parsegen_full_context_decides_after_sll_conflict:
  # ANTLR FullContextParsing: the choice in `e` is only settled by the
  # token after the call, which differs per caller.
  let rules = "s : 'if' e 'then' | 'for' e 'do' ;\ne : ID | ID INT ;"
  expectTree(rules, "if a 1 then", """
    s
    ├── 'if'
    ├── e
    │   ├── ID "a"
    │   └── INT "1"
    └── 'then'
    """)
  expectTree(rules, "for a do", """
    s
    ├── 'for'
    ├── e
    │   └── ID "a"
    └── 'do'
    """)

block parsegen_nested_shared_prefix_stress:
  # A recursive choice keeps the same `x` prefix at every level, with each
  # level deciding whether it owns a trailing `y`. This was exponential when
  # alternatives were reparsed speculatively.
  let rules = "s : a EOF ;\na : 'x' a 'y' | 'x' a | 'x' ;"
  var input = ""
  for _ in 0 ..< 18: input.add "x "
  for _ in 0 ..< 17: input.add "y "
  let got = tree(g(rules), input)
  doAssert got.startsWith("s\n└── a\n"), got
  # Callers that differ only in which alternative called `a` share one stack,
  # so configurations stay linear in the nesting depth.
  var (a, t, _) = analyzed(g(rules))
  a.predictionCache = newPredictionCache(trackWork = true)
  var diagnostics = Diagnostics(filename: "input")
  let n = a.interpret(tokenize[int](t, input, diagnostics), input,
    a.parserRules[0], diagnostics)
  doAssert n != nil and not diagnostics.hasErrors, $diagnostics.items
  doAssert a.predictionCache.predictionWork < 100_000,
    $a.predictionCache.predictionWork

block parsegen_ambiguous_loop_work_is_bounded:
  var previous = 0
  for size in [16, 32, 64]:
    var (a, t, _) = analyzed(g("s : ('x' | 'x' 'x')* 'z' EOF ;"))
    a.predictionCache = newPredictionCache(trackWork = true)
    var input = ""
    for _ in 0 ..< size: input.add "x "
    input.add "z"
    var diagnostics = Diagnostics(filename: "input")
    let n = a.interpret(tokenize[int](t, input, diagnostics), input,
      a.parserRules[0], diagnostics)
    doAssert n != nil and not diagnostics.hasErrors, $diagnostics.items
    let work = a.predictionCache.predictionWork
    if previous > 0:
      # This grammar needs the loop decision to inspect the remaining run of
      # shared-prefix tokens. Keep a generous quadratic bound to catch an
      # exponential regression without making a wall-clock assertion.
      doAssert work <= previous * 5, $previous & " -> " & $work
    previous = work

block parsegen_warm_dfa_does_no_atn_work:
  # SLL predictions walk the cached DFA; only a missing edge looks at the ATN.
  var (a, t, _) = analyzed(g("s : a* ;\na : ID ID 'x' | ID ID 'y' ;"))
  a.predictionCache = newPredictionCache(trackWork = true)
  var work: seq[int]
  for size in [100, 100, 1000]:
    var input = ""
    for i in 0 ..< size: input.add(if i mod 2 == 0: "p q x " else: "p q y ")
    var diagnostics = Diagnostics(filename: "input")
    let before = a.predictionCache.predictionWork
    let n = a.interpret(tokenize[int](t, input, diagnostics), input,
      a.parserRules[0], diagnostics)
    doAssert n != nil and not diagnostics.hasErrors, $diagnostics.items
    work.add a.predictionCache.predictionWork - before
  doAssert work[0] < 100 and work[1] == 0 and work[2] == 0, $work

proc warmWork(rules: string, inputs: openArray[string]): seq[int] =
  ## Prediction work of parsing each of `inputs` in turn with one cache.
  var (a, t, _) = analyzed(g(rules))
  a.predictionCache = newPredictionCache(trackWork = true)
  for input in inputs:
    var diagnostics = Diagnostics(filename: "input")
    let before = a.predictionCache.predictionWork
    let n = a.interpret(tokenize[int](t, input, diagnostics), input,
      a.parserRules[0], diagnostics)
    doAssert n != nil and not diagnostics.hasErrors, $diagnostics.items
    result.add a.predictionCache.predictionWork - before

block parsegen_completed_alternative_stays_in_sll:
  # `a`'s empty alternative leaves the rule at once; SLL follows it to the
  # call site instead of retrying in full context.
  let work = warmWork("s : (a ID ';')* ;\na : ID | ;",
    ["p q ; r ;", "p q ; r ; s t ; u ;"])
  doAssert work[1] == 0, $work

block parsegen_precedence_loop_stays_in_sll:
  # The loop exit leaves the rule at once too; the precedence filter keeps
  # SLL greedy, so a warm cache needs no ATN work.
  var long = "1"
  for i in 0 ..< 100: long.add(if i mod 3 == 0: " * 2" elif i mod 3 == 1: " + 3" else: " + +")
  let work = warmWork("e : e '*' e | e '+' e | e '+' '+' | INT ;",
    ["1 * 2 + 3 + + * 4", long, long])
  doAssert work[2] == 0, $work

block parsegen_explicit_eof_stays_in_sll:
  # At the end of the input SLL steps over an explicit `EOF` to see which
  # alternatives finish, so the decision needs no full context.
  var (a, t, _) = analyzed(g("s : ID EOF | ID ID EOF ;"))
  a.predictionCache = newPredictionCache(trackWork = true)
  for input in ["p", "p q"]:
    var diagnostics = Diagnostics(filename: "input")
    let n = a.interpret(tokenize[int](t, input, diagnostics), input,
      a.parserRules[0], diagnostics)
    doAssert n != nil and not diagnostics.hasErrors, $diagnostics.items
  doAssert a.predictionCache.fullContextPredictions == 0,
    $a.predictionCache.fullContextPredictions

block parsegen_full_context_keeps_nothing_in_the_cache:
  # `e` needs full context, under a call stack as deep as the nesting. The
  # cache that the parser keeps across parses holds only what SLL adds, so
  # deeper nesting adds nothing.
  var (a, t, _) = analyzed(g("""
s : '(' s ')' | x ;
x : '$' y | '@' z ;
y : e ID ;
z : e INT ID ;
e : INT | ;
"""))
  a.predictionCache = newPredictionCache(trackWork = true)
  var stacks: seq[int]
  for depth in [2, 3, 20]:
    let input = "(".repeat(depth) & " @ 34 abc " & ")".repeat(depth)
    var diagnostics = Diagnostics(filename: "input")
    let n = a.interpret(tokenize[int](t, input, diagnostics), input,
      a.parserRules[0], diagnostics)
    doAssert n != nil and not diagnostics.hasErrors, $diagnostics.items
    stacks.add a.predictionCache.cachedStacks
  doAssert a.predictionCache.fullContextPredictions == 3,
    $a.predictionCache.fullContextPredictions
  doAssert stacks[1] == stacks[0] and stacks[2] == stacks[0], $stacks

block parsegen_full_context_waits_for_one_lowest_alternative:
  # After `x y`, `d`'s first alternative shares a configuration with its
  # second and the second one with its third. Taking the lowest of them
  # there would fail on `x y y c`; as in ANTLR, full context reads on until
  # every group has the same lowest alternative.
  let rules = "s : d 'y'? 'c' EOF ;\nd : 'x' | 'x' 'y'? | 'x' 'y' ;"
  expectTree(rules, "x y y c", """
    s
    ├── d
    │   ├── 'x'
    │   └── 'y'
    ├── 'y'
    └── 'c'
    """)
  expectTree(rules, "x y c", """
    s
    ├── d
    │   └── 'x'
    ├── 'y'
    └── 'c'
    """)

block parsegen_context_sensitive_decision:
  # `e`'s alternatives meet after `a` or `b` with an empty context: a real
  # SLL conflict that full context resolves.
  let rules = "s : ('$' a | '@' b)* ;\na : e ID ;\nb : e INT ID ;\ne : INT | ;"
  expectTree(rules, "$ 1 x @ 2 y", """
    s
    ├── '$'
    ├── a
    │   ├── e
    │   │   └── INT "1"
    │   └── ID "x"
    ├── '@'
    └── b
        ├── e
        ├── INT "2"
        └── ID "y"
    """)

block parsegen_prediction_loops:
  let rules = "s : ID (',' ID)* ','? ;"
  expectTree(rules, "a, b,", """
    s
    ├── ID "a"
    ├── ','
    ├── ID "b"
    └── ','
    """)
  expectTree("s : ('a' ID)? 'a' INT ;", "a 1", """
    s
    ├── 'a'
    └── INT "1"
    """)
  expectTree("s : (ID ',')+ ID ;", "a, b", """
    s
    ├── ID "a"
    ├── ','
    └── ID "b"
    """)

block parsegen_prediction_operators:
  let rules = "e : e '[' e ']' # index | e '[' e ':' e ']' # slice | ID # name ;"
  expectTree(rules, "a[b:c]", """
    slice
    ├── name
    │   └── ID "a"
    ├── '['
    ├── name
    │   └── ID "b"
    ├── ':'
    ├── name
    │   └── ID "c"
    └── ']'
    """)

block parsegen_farthest_error:
  # the error is where parsing got farthest, not where the last attempt failed
  let rules = "s : x=ID '=' ID ';' # assign | ID ';' # name ;"
  expectError(rules, "a = ;", "1:5: expected ID but found ';'")
  expectError(rules, "a b", "1:3: expected '=' or ';' but found ID 'b'")

const exprRule = """
e : e '(' ')'                       # call
  | <assoc=right> left=e '^' right=e  # pow
  | '-' e                           # neg
  | left=e op=('*' | '/') right=e   # mul
  | left=e op=('+' | '-') right=e   # add
  | ID                              # name
  | '(' e ')'                       # paren
  ;
"""

proc shape(input: string): string =
  ## The tree of `input` with `exprRule`, as a parenthesized expression.
  let (a, t, _) = analyzed(g(exprRule))
  var d: Diagnostics
  let n = a.interpret(tokenize[int](t, input, d), input, 0, d)
  doAssert not d.hasErrors, $d.items
  proc show(n: Node): string =
    let kind = a.kinds[n.kind]
    case kind
    of "name": n.text
    of "paren": show(n[1])
    of "neg": "(-" & show(n[1]) & ")"
    of "call": show(n[0]) & "()"
    else: "(" & show(n[0]) & " " & n[1].text & " " & show(n[2]) & ")"
  show(n)

block parsegen_precedence:
  doAssert shape("a + b * c") == "(a + (b * c))"
  doAssert shape("a * b + c") == "((a * b) + c)"
  doAssert shape("a - b - c") == "((a - b) - c)"
  doAssert shape("a ^ b ^ c") == "(a ^ (b ^ c))"
  doAssert shape("a * b ^ c") == "(a * (b ^ c))"
  # prefix operands take the operators that bind tighter than the prefix
  doAssert shape("-a ^ b") == "(-(a ^ b))"
  doAssert shape("-a * b") == "((-a) * b)"
  doAssert shape("-a()") == "(-a())"
  doAssert shape("a()() + (b - c)") == "(a()() + (b - c))"

block parsegen_precedence_tree:
  expectTree(exprRule, "a * b()", """
    mul
    ├── left: name
    │   └── ID "a"
    ├── op: '*'
    └── right: call
        ├── name
        │   └── ID "b"
        ├── '('
        └── ')'
    """)
  # an unlabelled rule makes a node of the rule's kind per operator
  expectTree("e : e '+' e | INT ;", "1 + 2", """
    e
    ├── e
    │   └── INT "1"
    ├── '+'
    └── e
        └── INT "2"
    """)
  expectError(exprRule, "a +", "1:4: expected '(', '-' or ID but found end of input")
  expectError(exprRule, "a b",
    "1:3: expected end of input but found ID 'b'")

block parsegen_precedence_errors:
  expectProblem("e : e '+' e ;", "rule 'e' needs an alternative that does not start with 'e'")
  expectProblem("e : e '+' INT | ;", "left-recursive rule 'e' can match empty input")
  expectProblem("e : e '+'? | INT ;",
    "rule 'e': alternative 1 can match empty input after the leading 'e'")

block parsegen_precedence_expected:
  # the operators that could extend the expression are in the message
  expectError("s : e ';' ;\n" & exprRule, "a b",
    "1:3: expected ';' but found ID 'b'")
  # also after an operand that binds tighter, as the right side of '*'
  expectError("s : e ';' ;\n" & exprRule, "a * - b c",
    "1:9: expected ';' but found ID 'c'")

block parsegen_skipped_optionals_expected:
  # what skipped optional elements could have started is in the message
  let rules = "s : a NL ;\na : ID t=type? name=ID? args? ('export' INT)? '{'? ;\n" &
    "type : 'byte' ('[' INT? ']')? ;\nargs : '(' ')' ;\nNL : ';' ;"
  expectError(rules, "x byte byte",
    "1:8: expected 'export', '{', '[', '(', NL or ID but found 'byte'", "s")
  expectError(rules, "x y 1",
    "1:5: expected 'export', '{', '(' or NL but found INT '1'", "s")
  # loops that end, and decisions that take an empty alternative
  expectError("s : ID* INT? ';' ;", "x 1 x", "1:5: expected ';' but found ID 'x'")
  expectError("s : ID* INT? ';' ;", "x x", "1:4: expected ';', ID or INT but found end of input")
  expectError("s : ('a' | 'b' |) ';' ;", "c", "1:1: expected 'a', 'b' or ';' but found ID 'c'")
  expectError("s : ID+ ';' ;", "x 1", "1:3: expected ';' or ID but found INT '1'")

proc syntaxErrors(rules, input: string, formatter: SyntaxErrorFormatter = nil):
    seq[Diagnostic] =
  ## The errors from parsing `input` with the first rule.
  let (a, t, _) = analyzed(g(rules))
  var d = Diagnostics(filename: "input")
  discard a.interpret(tokenize[int](t, input, d), input, a.parserRules[0], d, formatter)
  d.sorted

block parsegen_found_token_text:
  # a token with a pattern shows its text, escaped and shortened
  expectError("s : INT ;", "abc", "1:1: expected INT but found ID 'abc'")
  expectError("s : INT ;", "abcdefghijklmnopqrstuvwxyz",
    "1:1: expected INT but found ID 'abcdefghijklmnopqrst...'")
  let rules = "s : ID ;\nS : '\"' ~'\"'* '\"' ;"
  expectError(rules, "\"a\tb'\\\"", "1:1: expected ID but found S '\"a\\tb\\'\\\\\"'")
  # literals, EOF and white space keep their name
  expectError("s : ID ';' ;", ";", "1:1: expected ID but found ';'")
  expectError("s : ID INT ;", "x", "1:2: expected INT but found end of input")
  expectError("s : ID ;\nNL : ';' [\\n]* ;", ";\n", "1:1: expected ID but found NL ';\\n'")
  expectError("s : ID+ ;\nNL : '\\r'? '\\n' ;", "x\n", "1:2: expected ID but found NL")

block parsegen_syntax_error_info:
  # each syntax error keeps what it is about
  let errors = syntaxErrors("s : a ';' ;\na : '(' INT? ')' ;", "( x ;")
  doAssert errors.len == 1, $errors
  let e = errors[0].syntax
  doAssert e != nil and e.hasToken
  doAssert e.pos == SourcePos(line: 1, col: 3) and e.text == "x"
  doAssert e.msg == "expected ')' or INT but found ID 'x'" and e.msg == errors[0].msg
  doAssert e.rules == @["s", "a"], $e.rules
  let (a, _, _) = analyzed(g("s : a ';' ;\na : '(' INT? ')' ;"))
  var names: seq[string]
  for k in e.expected: names.add a.v.tokens[k].name
  doAssert names == @["')'", "INT"] and a.v.tokens[e.found].name == "ID", $names
  # a lexer error has no token, only the character
  let lexed = syntaxErrors("s : ID ;", "x $")
  doAssert lexed.len == 1 and lexed[0].syntax != nil and not lexed[0].syntax.hasToken
  doAssert lexed[0].syntax.text == "$" and lexed[0].msg == "unexpected character '$'"
  # other diagnostics have none
  var d: Diagnostics
  d.error(SourcePos(line: 1, col: 1), "not a syntax error")
  doAssert d.items[0].syntax == nil

block parsegen_formatter:
  # a formatter words every syntax error, the lexer's too
  proc words(e: SyntaxErrorInfo): string =
    if e.hasToken: "wanted " & $e.expected.len & " kinds in " & e.rules[^1] & ", got " & e.text
    else: "bad character " & e.text
  let errors = syntaxErrors("s : '(' ID ')' ;", "( $ 1 )", words)
  var msgs: seq[string]
  for x in errors: msgs.add x.msg
  doAssert msgs == @["bad character $", "wanted 1 kinds in s, got 1"], $msgs
  doAssert errors[1].syntax.msg == "expected ID but found INT '1'"

block parsegen_left_recursion:
  # left recursion through another rule, or not at the start of an
  # alternative, is not rewritten
  expectProblem("e : (e) '+' INT | INT ;", "2:1: error: rule 'e' is left-recursive: e -> e")
  expectProblem("a : b ID ;\nb : c? a | INT ;\nc : '-' ;",
    "rule 'a' is left-recursive: a -> b -> a")
  expectProblem("a : b ID ;\nb : c? a | INT ;\nc : '-' ;",
    "rule 'b' is left-recursive: b -> a -> b")
  doAssert problems(g("a : '(' a ')' | ID ;")).len == 0

block parsegen_reserved_labels:
  expectProblem("s : text=ID ;", "label 'text' clashes with the parse tree API")
  expectProblem("s : edge=ID ;", "label 'edge' clashes with the parse tree API")
  # `label` is free
  doAssert problems(g("s : label=ID ':' ;")).len == 0
  expectTree("s : label=ID ':' ;", "x :", """
    s
    ├── label: ID "x"
    └── ':'
    """)

block parsegen_unlabelled_tokens:
  # a token without a label is found by its kind
  let (a, t, _) = analyzed(g("s : 'virtual'? ID ;"))
  var d: Diagnostics
  let virtual = a.v.byLiteral["virtual"]
  let n = a.interpret(tokenize[int](t, "virtual x", d), "virtual x", 0, d)
  doAssert n.has(virtual) and n.token(virtual).text == "virtual"
  let m = a.interpret(tokenize[int](t, "x", d), "x", 0, d)
  doAssert not m.has(virtual) and m.token(virtual) == nil
  doAssert not d.hasErrors, $d.items

block parsegen_node_kinds:
  let (a, _, _) = analyzed(g("s : x # if | y # token ;\nx : ID ;\ny : t=INT ;\ntoken : ID ;"))
  # a label shares the node kind of a rule with the same name
  doAssert a.kinds == @["token", "error", "if", "token", "x", "y"], $a.kinds
  doAssert a.kindIdents == @["nkToken", "nkError", "nkIf", "nkToken2", "nkX", "nkY"],
    $a.kindIdents
  doAssert a.labels == @["", "t"]
  doAssert a.labelIdents == @["lbNone", "lbT"]
