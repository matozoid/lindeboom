## Parses input with a grammar directly, without generating code. Makes the
## same decisions and builds the same tree as the generated parser.

import std/[packedsets, tables]
import ../runtime/parser, ../grammar/[ast, vocabulary], ./analysis

type
  Node* = ParseNode[int, int, int]
  Parser = ParserState[int, int, int]

proc candidates(a: Analysis, p: var Parser, alts: seq[GExpr]): seq[int] =
  ## The alternatives that the current token can start, in order. When it
  ## only follows them, what could have started one is expected there too.
  var first: TokenSet
  for i, alt in alts:
    if p.peek in a.predict(alt): result.add i
    first.incl a.first(alt)
  if result.len == 0: p.fail(a.expected(alts))
  elif p.peek notin first: p.expect(first)

func hasPredictionConflict(a: Analysis, alts: seq[GExpr]): bool =
  for i, left in alts:
    let leftSet = a.predict(left)
    for j in i + 1 .. alts.high:
      if (leftSet * a.predict(alts[j])).len > 0: return true

proc adaptivePredict(a: Analysis, p: var Parser, decision: int, precedence = 0): int =
  result = p.predict(decision, a.atn, a.decisions, a.atRules,
    a.predictionCache, precedence)

proc runRule(a: Analysis, p: var Parser, r: int, prec = 0, returnState = -1): Node

proc run(a: Analysis, p: var Parser, n: Node, e: GExpr, label: int)

proc runLoop(a: Analysis, p: var Parser, n: Node, e: GExpr, label: int) =
  ## The iterations of `*` or `+` after the first one.
  let first = a.first(e.inner)
  let follow = a.grammarFollow(e)
  if a.isAmbiguous(e):
    while a.adaptivePredict(p, a.decisionByExpr[e]) == 0:
      a.run(p, n, e.inner, label)
    p.expect(first)
  else:
    while p.more(n, first, follow): a.run(p, n, e.inner, label)

proc run(a: Analysis, p: var Parser, n: Node, e: GExpr, label: int) =
  let label = if e.label.len > 0: a.labelIndex[e.label] else: label
  if e.isTokenSet:
    let s = a.tokens(e)
    if p.peek notin s: p.fail(s)
    p.take(n, label)
  else:
    case e.kind
    of ekSeq:
      for x in e.items: a.run(p, n, x, label)
    of ekAlt:
      if a.hasPredictionConflict(e.items):
        a.run(p, n, e.items[a.adaptivePredict(p, a.decisionByExpr[e])], label)
      else:
        let cands = a.candidates(p, e.items)
        a.run(p, n, e.items[cands[0]], label)
    of ekOpt:
      if p.peek in a.first(e.inner):
        if a.isAmbiguous(e):
          if a.adaptivePredict(p, a.decisionByExpr[e]) == 0:
            a.run(p, n, e.inner, label)
        else: a.run(p, n, e.inner, label)
      else:
        p.expect(a.first(e.inner))
    of ekStar:
      a.runLoop(p, n, e, label)
    of ekPlus:
      a.run(p, n, e.inner, label)
      a.runLoop(p, n, e, label)
    of ekRuleRef:
      n.add(a.runRule(p, a.ruleIndex[e.name], a.operandPrec.getOrDefault(e),
        a.callReturn[e]), label)
    of ekLiteral, ekTokenRef:
      let k = a.tokenKind(e)
      if p.peek != k: p.fail([k])
      p.take(n, label)
    else:
      raiseAssert "not a parser element: " & $e.kind

func isLabelled(a: Analysis, r: int): bool =
  ## Whether the alternatives of rule `r` have labels, and so node kinds of
  ## their own.
  a.g.rules[r].alts[0].label.len > 0

proc runAlt(a: Analysis, p: var Parser, r, k: int, n: var Node) =
  ## Alternative `k` of rule `r`, a primary or prefix one if `r` is a
  ## precedence rule, into `n`, or a new node for a labelled alternative.
  if a.isLabelled(r): n = p.newNode(a.altKinds[r][k])
  a.run(p, n, a.g.rules[r].alts[k].body, 0)

proc extend(a: Analysis, p: var Parser, r, k: int, n: var Node) =
  ## Binary or suffix alternative `k` of rule `r` after the expression `n`.
  let items = a.g.rules[r].alts[k].body.items
  let label = if items[0].label.len > 0: a.labelIndex[items[0].label] else: 0
  n = p.wrap(n, a.altKinds[r][k], label)
  for x in items[1 .. ^1]: a.run(p, n, x, 0)

proc runRuleBody(a: Analysis, p: var Parser, r, prec: int, result: var Node) =
  let alts = a.g.rules[r].alts
  var heads: seq[int]
  var bodies: seq[GExpr]
  for k in 0 .. alts.high:
    if not a.isLoopAlt(r, k):
      heads.add k
      bodies.add alts[k].body
  if not a.isLabelled(r): result = p.newNode(a.altKinds[r][0])
  var done = false
  if bodies.len > 1 and a.hasPredictionConflict(bodies):
    let choice = a.adaptivePredict(p, a.ruleDecision[r])
    a.runAlt(p, r, heads[choice], result)
  else:
    let cands = if heads.len == 1: @[0] else: a.candidates(p, bodies)
    a.runAlt(p, r, heads[cands[0]], result)
    done = true
  if a.isPrecRule[r]:
    while true:
      let choice = a.adaptivePredict(p, a.loopDecision[r], prec)
      if choice == high(int): break
      a.extend(p, r, choice, result)

proc runRule(a: Analysis, p: var Parser, r: int, prec = 0, returnState = -1): Node =
  p.enter(r, returnState, prec)
  try:
    a.runRuleBody(p, r, prec, result)
  except SyntaxError:
    p.recover(result)
  p.leave()

func treeNames*(a: Analysis): TreeNames =
  result = TreeNames(kinds: a.kinds, labels: a.labels)
  for t in a.v.tokens: result.tokens.add t.name

proc interpret*(a: Analysis, tokens: seq[LexerToken[int]], src: string, rule: int,
    d: var Diagnostics, formatter: SyntaxErrorFormatter = nil): Node =
  ## Parses `tokens` (from `tokenize`) starting at `g.rules[rule]`, which must
  ## be followed by the end of the input. Syntax errors are added to `d`; the
  ## tree has error nodes where the parser recovered from them. The syntax
  ## errors in `d`, the lexer's too, are worded by `formatter` if there is
  ## one.
  var names, ruleNames: seq[string]
  for t in a.v.tokens: names.add t.name
  for r in a.g.rules: ruleNames.add r.name
  var follows = newSeq[TokenSet](a.g.rules.len)
  for r in a.parserRules: follows[r] = a.ruleFollow(r)
  var p = initParserState[int, int, int](tokens, src, names, ruleNames,
    proc (r, kind: int): bool = kind in follows[r])
  result = a.runRule(p, rule, 0, -1)
  if p.retryInFullContext(result): result = a.runRule(p, rule, 0, -1)
  p.finish(result, d)
  d.formatSyntaxErrors(formatter)
