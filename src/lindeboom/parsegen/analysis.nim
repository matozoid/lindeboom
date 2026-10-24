## Grammar analysis: nullable, FIRST and FOLLOW sets, left recursion,
## adaptive transition networks, and parse-tree node kinds and labels.
##
## Every rule can be a start rule, so every rule can be followed by EOF.
##
## Where one token of lookahead is not enough, the parser predicts with the
## analyzed ATN and the active rule-call context.
##
## A rule with an alternative that starts with the rule itself is a
## precedence rule, parsed by precedence climbing as in ANTLR 4: its
## primary and prefix alternatives start an expression, its binary and
## suffix alternatives extend it. Alternative k of n has precedence n - k,
## so earlier alternatives bind tighter.

import std/[algorithm, hashes, packedsets, sets, tables]
import ../runtime/[diagnostics, parser], ../grammar/[ast, idents, vocabulary]

type
  TokenSet* = PackedSet[int]

  AtEdge* = AtnEdgeData
  AtState* = AtnStateData
  AtDecision* = AtnDecisionData
  AtRule* = AtnRuleData

  AltShape* = enum
    asPrimary  ## `'(' e ')'`, `ID`
    asPrefix   ## `'-' e`
    asBinary   ## `e '+' e`
    asSuffix   ## `e '(' args ')'`

  Analysis* = object
    g*: Grammar
    v*: Vocabulary
    ruleIndex*: Table[string, int]       ## parser rule name -> index in `g.rules`
    parserRules*: seq[int]               ## indices of the parser rules
    ruleIdents*: seq[string]             ## per rule: `IfStmt` for `ifStmt`
    nullable: Table[GExpr, bool]
    first: Table[GExpr, TokenSet]
    follow: Table[GExpr, TokenSet]
    grammarFollow: Table[GExpr, TokenSet]  ## FOLLOW without the start-rule EOF
    visible: TokenSet                    ## tokens the parser can see, except EOF
    ruleNullable: seq[bool]
    ruleFirst, ruleFollow: seq[TokenSet]
    kinds*: seq[string]                  ## node kind names; 0 is "token", 1 "error"
    kindIdents*: seq[string]             ## `nkToken`, `nkError`, `nkIf`, ...
    altKinds*: seq[seq[int]]             ## per rule and alternative: node kind
    labels*: seq[string]                 ## element labels; 0 is ""
    labelIdents*: seq[string]            ## `lbNone`, `lbCond`, ...
    accessorIdents*: seq[string]         ## the accessor of each label; 0 is ""
    labelIsList*: seq[bool]              ## can label several sons of a node
    labelIndex*: Table[string, int]
    isPrecRule*: seq[bool]               ## per rule
    shapes*: seq[seq[AltShape]]          ## per precedence rule and alternative
    operandPrec*: Table[GExpr, int]      ## trailing self-reference -> precedence
    atn*: seq[AtState]                    ## Thompson network for parser rules
    atRules*: seq[AtRule]                 ## indexed by grammar rule
    decisions*: seq[AtDecision]
    decisionByExpr*: Table[GExpr, int]
    ruleDecision*: seq[int]                ## decision id, or -1 for a single-alternative rule
    loopDecision*: seq[int]
    callReturn*: Table[GExpr, int]           ## ATN return state at each rule call site
    predictionCache*: PredictionCache

const reservedLabels = ["kind", "edge", "tok", "sons", "len", "text", "pos",
  "items", "treeRepr"]

func hash(e: GExpr): Hash = hash(cast[pointer](e))

func visibleTokens(g: Grammar, v: Vocabulary): TokenSet =
  ## Every token kind except EOF and those that are always skipped or hidden.
  for k, t in v.tokens:
    if t.source in {tsLiteral, tsImaginary}: result.incl k
  for r in g.rules:
    if r.kind == rkLexer and not r.isFragment:
      for alt in r.alts:
        var kind = v.byName[r.name]
        var emit = true
        for cmd in alt.commands:
          case cmd.kind
          of lcSkip, lcChannel: emit = false
          of lcType: kind = v.byName[cmd.arg]
        if emit: result.incl kind

func tokenKind*(a: Analysis, e: GExpr): int =
  ## Kind of a literal or token reference.
  if e.kind == ekLiteral: a.v.byLiteral[e.text]
  elif e.name == "EOF": 0
  else: a.v.byName[e.name]

func isSingleToken(e: GExpr): bool =
  case e.kind
  of ekLiteral, ekTokenRef: true
  of ekSeq: e.items.len == 1 and e.items[0].label.len == 0 and e.items[0].isSingleToken
  else: false

func isTokenSet*(e: GExpr): bool =
  ## Matches one token out of a set: `.`, `~x` and `(A | B)`.
  case e.kind
  of ekWildcard, ekNot: true
  of ekAlt:
    for x in e.items:
      if x.label.len > 0 or not x.isSingleToken: return false
    true
  else: false

func tokens*(a: Analysis, e: GExpr): TokenSet =
  ## The tokens matched by a single token or token set.
  case e.kind
  of ekLiteral, ekTokenRef: result.incl a.tokenKind(e)
  of ekSeq, ekAlt:
    for x in e.items: result.incl a.tokens(x)
  of ekWildcard: result = a.visible
  of ekNot:
    result = a.visible
    result.excl a.tokens(e.inner)
  else: raiseAssert "not a token set: " & $e.kind

# ---- nullable and FIRST ----

proc computeNullable(a: var Analysis, e: GExpr): bool =
  ## Stores the result for `e` and its sub-expressions.
  case e.kind
  of ekSeq:
    result = true
    for x in e.items:
      if not a.computeNullable(x): result = false
  of ekAlt:
    result = false
    for x in e.items:
      if a.computeNullable(x): result = true
  of ekOpt, ekStar:
    discard a.computeNullable(e.inner)
    result = true
  of ekPlus: result = a.computeNullable(e.inner)
  of ekRuleRef: result = a.ruleNullable[a.ruleIndex[e.name]]
  else: result = false
  a.nullable[e] = result

proc computeFirst(a: var Analysis, e: GExpr): TokenSet =
  ## Stores the result for `e` and its sub-expressions. Needs `nullable`.
  if e.isTokenSet:
    result = a.tokens(e)
  else:
    case e.kind
    of ekSeq:
      var open = true
      for x in e.items:
        let f = a.computeFirst(x)
        if open: result.incl f
        open = open and a.nullable[x]
    of ekAlt:
      for x in e.items: result.incl a.computeFirst(x)
    of ekOpt, ekStar, ekPlus: result = a.computeFirst(e.inner)
    of ekRuleRef: result = a.ruleFirst[a.ruleIndex[e.name]]
    of ekLiteral, ekTokenRef: result = a.tokens(e)
    else: raiseAssert "not a parser element: " & $e.kind
  a.first[e] = result

proc computeFirstSets(a: var Analysis) =
  ## Fixpoint over the rules.
  var changed = true
  while changed:
    changed = false
    for i in a.parserRules:
      var n = false
      for alt in a.g.rules[i].alts:
        if a.computeNullable(alt.body): n = true
      if n != a.ruleNullable[i]:
        a.ruleNullable[i] = n
        changed = true
  changed = true
  while changed:
    changed = false
    for i in a.parserRules:
      var f: TokenSet
      for alt in a.g.rules[i].alts: f.incl a.computeFirst(alt.body)
      if f != a.ruleFirst[i]:
        a.ruleFirst[i] = f
        changed = true

# ---- FOLLOW ----

proc computeFollow(a: Analysis, e: GExpr, follow: TokenSet,
    sets: var Table[GExpr, TokenSet], ruleFollow: var seq[TokenSet], changed: var bool) =
  sets[e] = follow
  if not e.isTokenSet:
    case e.kind
    of ekSeq:
      var f = follow
      for i in countdown(e.items.high, 0):
        let x = e.items[i]
        a.computeFollow(x, f, sets, ruleFollow, changed)
        if a.nullable[x]: f.incl a.first[x]
        else: f = a.first[x]
    of ekAlt:
      for x in e.items: a.computeFollow(x, follow, sets, ruleFollow, changed)
    of ekOpt:
      a.computeFollow(e.inner, follow, sets, ruleFollow, changed)
    of ekStar, ekPlus:
      var f = follow
      f.incl a.first[e.inner]
      a.computeFollow(e.inner, f, sets, ruleFollow, changed)
    of ekRuleRef:
      let r = a.ruleIndex[e.name]
      if not (follow <= ruleFollow[r]):
        ruleFollow[r].incl follow
        changed = true
    else:
      discard

proc computeFollowSets(a: Analysis, startEof: bool, sets: var Table[GExpr, TokenSet],
    ruleFollow: var seq[TokenSet]) =
  ## With `startEof`, every rule can be followed by EOF, as a start rule.
  ruleFollow.setLen a.g.rules.len
  if startEof:
    for i in a.parserRules: ruleFollow[i].incl 0
  var changed = true
  while changed:
    changed = false
    for i in a.parserRules:
      for alt in a.g.rules[i].alts:
        a.computeFollow(alt.body, ruleFollow[i], sets, ruleFollow, changed)

func predict*(a: Analysis, e: GExpr): TokenSet =
  ## Tokens that select `e` at a decision: its FIRST set, plus its FOLLOW set
  ## if it can match empty input.
  result = a.first[e]
  if a.nullable[e]: result.incl a.follow[e]

func first*(a: Analysis, e: GExpr): TokenSet = a.first[e]

func follow*(a: Analysis, e: GExpr): TokenSet = a.follow[e]

func grammarFollow*(a: Analysis, e: GExpr): TokenSet =
  ## FOLLOW of `e` without the EOF that can follow any start rule; for error
  ## messages.
  a.grammarFollow[e]

func expected*(a: Analysis, alts: seq[GExpr]): TokenSet =
  ## Tokens to list when none of `alts` can start at the current token: as
  ## `predict`, but with `grammarFollow`.
  for e in alts:
    result.incl a.first[e]
    if a.nullable[e]: result.incl a.grammarFollow[e]

func ruleFollow*(a: Analysis, r: int): TokenSet =
  ## Tokens that can follow rule `r`, wherever it is used.
  a.ruleFollow[r]

func isAmbiguous*(a: Analysis, e: GExpr): bool =
  ## Whether the next token can both start and follow the `?`, `*` or `+`
  ## element `e`, which prediction then has to settle.
  (a.first[e.inner] * a.follow[e]).len > 0

func sortedKinds*(s: TokenSet): seq[int] =
  for k in s: result.add k
  result.sort()

# ---- precedence rules ----

func isSelfRef(e: GExpr, rule: string): bool =
  e.kind == ekRuleRef and e.name == rule

func precedence*(a: Analysis, r, k: int): int =
  ## Precedence of alternative `k` of rule `r`.
  a.g.rules[r].alts.len - k

func isLoopAlt*(a: Analysis, r, k: int): bool =
  ## A binary or suffix alternative, which extends an expression.
  a.isPrecRule[r] and a.shapes[r][k] in {asBinary, asSuffix}

func continuation*(a: Analysis, alt: GExpr): TokenSet =
  ## FIRST of a binary or suffix alternative after its leading self-reference.
  var i = 1
  while i < alt.items.len:
    result.incl a.first[alt.items[i]]
    i = if a.nullable[alt.items[i]]: i + 1 else: alt.items.len

func loopContinuation*(a: Analysis, r: int): TokenSet =
  ## The tokens that can extend an expression of precedence rule `r`: the
  ## continuations of all its binary and suffix alternatives.
  for k, alt in a.g.rules[r].alts:
    if a.isLoopAlt(r, k): result.incl a.continuation(alt.body)

func continuationNullable(a: Analysis, alt: GExpr): bool =
  result = true
  for i in 1 .. alt.items.high:
    if not a.nullable[alt.items[i]]: result = false

proc classify(a: var Analysis, d: var Diagnostics) =
  a.isPrecRule.setLen a.g.rules.len
  a.shapes.setLen a.g.rules.len
  for i in a.parserRules:
    let r = a.g.rules[i]
    for alt in r.alts:
      if alt.body.items.len > 0 and alt.body.items[0].isSelfRef(r.name):
        a.isPrecRule[i] = true
    if a.isPrecRule[i]:
      var hasHead = false
      for k, alt in r.alts:
        let items = alt.body.items
        let leading = items.len > 0 and items[0].isSelfRef(r.name)
        let trailing = items.len > 1 and items[^1].isSelfRef(r.name)
        let shape =
          if leading and trailing: asBinary
          elif leading: asSuffix
          elif trailing: asPrefix
          else: asPrimary
        a.shapes[i].add shape
        case shape
        of asBinary:
          let assoc = if alt.hasAssoc: alt.assoc else: assocLeft
          a.operandPrec[items[^1]] = a.precedence(i, k) + ord(assoc == assocLeft)
        of asPrefix:
          a.operandPrec[items[^1]] = a.precedence(i, k)
        of asPrimary, asSuffix:
          discard
        if leading and a.continuationNullable(alt.body):
          d.error(alt.pos, "rule '" & r.name & "': alternative " & $(k + 1) &
            " can match empty input after the leading '" & r.name & "'")
        hasHead = hasHead or not leading
      if not hasHead:
        d.error(r.pos, "rule '" & r.name & "' needs an alternative that does not start with '" &
          r.name & "'")
      elif a.ruleNullable[i]:
        d.error(r.pos, "left-recursive rule '" & r.name & "' can match empty input")

# ---- left recursion ----

proc leftRefs(a: Analysis, e: GExpr, refs: var seq[int]) =
  ## Rules that `e` can call before consuming a token.
  case e.kind
  of ekSeq:
    var i = 0
    while i < e.items.len:
      a.leftRefs(e.items[i], refs)
      i = if a.nullable[e.items[i]]: i + 1 else: e.items.len
  of ekAlt:
    for x in e.items: a.leftRefs(x, refs)
  of ekOpt, ekStar, ekPlus:
    a.leftRefs(e.inner, refs)
  of ekRuleRef:
    refs.add a.ruleIndex[e.name]
  else:
    discard

func leftCycle(a: Analysis, calls: seq[seq[int]], start: int): seq[int] =
  ## Shortest path of left calls from `start` back to itself, empty if none.
  var parent = newSeq[int](a.g.rules.len)
  for x in parent.mitems: x = -1
  var queue = @[start]
  var found = false
  var qi = 0
  while qi < queue.len and not found:
    let r = queue[qi]
    inc qi
    for c in calls[r]:
      if c == start and not found:
        found = true
        result = @[start]
        var x = r
        while x != start:
          result.add x
          x = parent[x]
        result.add start
        result.reverse()
      elif c != start and parent[c] < 0:
        parent[c] = r
        queue.add c

proc checkLeftRecursion(a: Analysis, d: var Diagnostics): HashSet[int] =
  ## Reports left recursion that is not handled by precedence climbing and
  ## returns the rules involved.
  var calls = newSeq[seq[int]](a.g.rules.len)
  for i in a.parserRules:
    for k, alt in a.g.rules[i].alts:
      if not a.isLoopAlt(i, k): a.leftRefs(alt.body, calls[i])
  for i in a.parserRules:
    let cycle = a.leftCycle(calls, i)
    if cycle.len > 0:
      result.incl i
      var path = ""
      for k, r in cycle:
        if k > 0: path.add " -> "
        path.add a.g.rules[r].name
      d.error(a.g.rules[i].pos, "rule '" & a.g.rules[i].name & "' is left-recursive: " & path)

# ---- augmented transition network ----

proc newAtState(a: var Analysis): int =
  result = a.atn.len
  a.atn.add AtState()

proc epsilon(a: var Analysis, fromState, toState: int, minimumPrecedence = -1) =
  a.atn[fromState].edges.add AtEdge(kind: atEpsilon, target: toState,
    rule: -1, minimumPrecedence: minimumPrecedence)

proc compileExpr(a: var Analysis, e: GExpr, fromState, toState: int, owner: int)

proc compileExpr(a: var Analysis, e: GExpr, fromState, toState: int, owner: int) =
  case e.kind
  of ekSeq:
    # Sequence children may contain their own prediction decisions.
    if e.items.len == 0:
      a.epsilon(fromState, toState)
    else:
      var current = fromState
      for i, item in e.items:
        let next = if i == e.items.high: toState else: a.newAtState()
        a.compileExpr(item, current, next, owner)
        current = next
  of ekAlt:
    var decision = AtDecision(state: fromState, rule: owner)
    for branch in e.items:
      let entry = a.newAtState()
      let exit = a.newAtState()
      decision.alternatives.add entry
      a.epsilon(fromState, entry)
      a.compileExpr(branch, entry, exit, owner)
      a.epsilon(exit, toState)
    a.decisionByExpr[e] = a.decisions.len
    a.decisions.add decision
  of ekOpt:
    let entry = a.newAtState()
    a.epsilon(fromState, entry)
    a.epsilon(fromState, toState)
    a.compileExpr(e.inner, entry, toState, owner)
    a.decisionByExpr[e] = a.decisions.len
    a.decisions.add AtDecision(state: fromState, alternatives: @[entry, toState],
      rule: owner)
  of ekStar, ekPlus:
    if e.kind == ekStar:
      let entry = a.newAtState()
      a.epsilon(fromState, entry)
      a.epsilon(fromState, toState)
      a.compileExpr(e.inner, entry, fromState, owner)
      a.decisionByExpr[e] = a.decisions.len
      a.decisions.add AtDecision(state: fromState, alternatives: @[entry, toState],
        rule: owner)
    else:
      let first = a.newAtState()
      let repeat = a.newAtState()
      let next = a.newAtState()
      a.epsilon(fromState, first)
      a.compileExpr(e.inner, first, repeat, owner)
      a.epsilon(repeat, next)
      a.epsilon(repeat, toState)
      a.compileExpr(e.inner, next, repeat, owner)
      a.decisionByExpr[e] = a.decisions.len
      a.decisions.add AtDecision(state: repeat, alternatives: @[next, toState],
        rule: owner)
  of ekRuleRef:
    a.callReturn[e] = toState
    a.atn[fromState].edges.add AtEdge(kind: atCall,
      target: toState, rule: a.ruleIndex[e.name],
      minimumPrecedence: a.operandPrec.getOrDefault(e))
  of ekLiteral, ekTokenRef:
    a.atn[fromState].edges.add AtEdge(kind: atTokens, target: toState, rule: -1,
      tokens: a.tokens(e).sortedKinds, minimumPrecedence: -1)
  of ekWildcard, ekNot:
    a.atn[fromState].edges.add AtEdge(kind: atTokens, target: toState, rule: -1,
      tokens: a.tokens(e).sortedKinds, minimumPrecedence: -1)
  of ekCharSet, ekRange:
    raiseAssert "lexer expression in parser ATN"

proc buildAtn(a: var Analysis) =
  ## Builds a Thompson-style ATN. Calls remain explicit edges so prediction
  ## can carry caller context instead of expanding recursive rules.
  a.atRules.setLen a.g.rules.len
  a.ruleDecision = newSeq[int](a.g.rules.len)
  a.loopDecision = newSeq[int](a.g.rules.len)
  for id in a.ruleDecision.mitems: id = -1
  for id in a.loopDecision.mitems: id = -1
  for i in a.parserRules:
    let start = a.newAtState()
    let stop = a.newAtState()
    a.atRules[i] = AtRule(start: start, stop: stop)
    let alts = a.g.rules[i].alts
    if a.isPrecRule[i]:
      # Predict over the rewritten expression shape: one primary/prefix,
      # followed by zero or more operator/suffix tails. A literal left
      # recursive call would create an epsilon cycle during ATN closure.
      let loop = a.newAtState()
      var heads: seq[int]
      for k in 0 .. alts.high:
        if not a.isLoopAlt(i, k): heads.add k
      if heads.len > 1:
        var decision = AtDecision(state: start, rule: i)
        for k in heads:
          let entry = a.newAtState()
          let exit = a.newAtState()
          decision.alternatives.add entry
          a.epsilon(start, entry)
          a.compileExpr(alts[k].body, entry, exit, i)
          a.epsilon(exit, loop)
        a.ruleDecision[i] = a.decisions.len
        a.decisions.add decision
      elif heads.len == 1:
        a.compileExpr(alts[heads[0]].body, start, loop, i)
      a.epsilon(loop, stop)
      var loopChoice = AtDecision(state: loop, rule: i)
      for k, alt in alts:
        if a.isLoopAlt(i, k):
          let entry = a.newAtState()
          let exit = a.newAtState()
          let minimum = a.precedence(i, k)
          loopChoice.alternatives.add entry
          loopChoice.alternativeIds.add k
          loopChoice.minimums.add minimum
          a.epsilon(loop, entry, minimum)
          let items = alt.body.items
          var current = entry
          for j in 1 .. items.high:
            let next = if j == items.high: exit else: a.newAtState()
            a.compileExpr(items[j], current, next, i)
            current = next
          a.epsilon(exit, loop)
      loopChoice.alternatives.add stop
      loopChoice.alternativeIds.add loopExit
      loopChoice.minimums.add -1
      a.loopDecision[i] = a.decisions.len
      a.decisions.add loopChoice
    elif alts.len > 1:
      var decision = AtDecision(state: start, rule: i)
      for alt in alts:
        let entry = a.newAtState()
        let exit = a.newAtState()
        decision.alternatives.add entry
        a.epsilon(start, entry)
        a.compileExpr(alt.body, entry, exit, i)
        a.epsilon(exit, stop)
      a.ruleDecision[i] = a.decisions.len
      a.decisions.add decision
    else:
      a.compileExpr(alts[0].body, start, stop, i)

# ---- node kinds and labels ----

func countLabels(a: Analysis, e: GExpr, inherited: string,
    counts: var Table[string, int]) =
  ## Adds to `counts` how many sons of one node `e` can add per label, where
  ## 2 stands for "more than one".
  let label = if e.label.len > 0: e.label else: inherited
  if e.isTokenSet or e.kind in {ekRuleRef, ekLiteral, ekTokenRef}:
    if label.len > 0: counts[label] = min(counts.getOrDefault(label) + 1, 2)
  else:
    case e.kind
    of ekSeq:
      for x in e.items: a.countLabels(x, label, counts)
    of ekAlt:
      var most: Table[string, int]
      for x in e.items:
        var c: Table[string, int]
        a.countLabels(x, label, c)
        for k, n in c: most[k] = max(most.getOrDefault(k), n)
      for k, n in most: counts[k] = min(counts.getOrDefault(k) + n, 2)
    of ekOpt:
      a.countLabels(e.inner, label, counts)
    of ekStar, ekPlus:
      var c: Table[string, int]
      a.countLabels(e.inner, label, c)
      for k in c.keys: counts[k] = 2
    else:
      discard

proc assignNames(a: var Analysis, d: var Diagnostics) =
  var kindIndex: Table[string, int]
  var kindUsed, ruleUsed, labelUsed: HashSet[string]
  # Accessors are procs on `Node`, beside the tree API's.
  var accessorUsed: HashSet[string]
  for name in reservedLabels: accessorUsed.incl nimNormalize(name)
  a.kinds = @["token", "error"]
  a.kindIdents = @[uniqueIdent("nkToken", kindUsed), uniqueIdent("nkError", kindUsed)]
  a.labels = @[""]
  a.labelIdents = @[uniqueIdent("lbNone", labelUsed)]
  a.accessorIdents = @[""]
  a.labelIsList = @[false]
  a.altKinds.setLen a.g.rules.len
  a.ruleIdents.setLen a.g.rules.len
  for i in a.parserRules:
    let r = a.g.rules[i]
    a.ruleIdents[i] = uniqueIdent(capitalized(r.name), ruleUsed)
    for alt in r.alts:
      let name = if alt.label.len > 0: alt.label else: r.name
      if name notin kindIndex:
        kindIndex[name] = a.kinds.len
        a.kinds.add name
        a.kindIdents.add uniqueIdent("nk" & capitalized(name), kindUsed)
      a.altKinds[i].add kindIndex[name]
      for e in alt.body.walk:
        if e.label.len > 0 and e.label notin a.labelIndex:
          if e.label in reservedLabels:
            d.error(e.pos, "label '" & e.label &
              "' clashes with the parse tree API; choose another name")
          a.labelIndex[e.label] = a.labels.len
          a.labels.add e.label
          a.labelIdents.add uniqueIdent("lb" & capitalized(e.label), labelUsed)
          a.accessorIdents.add uniqueIdent(e.label, accessorUsed)
          a.labelIsList.add false
      var counts: Table[string, int]
      a.countLabels(alt.body, "", counts)
      for label, n in counts:
        if n > 1: a.labelIsList[a.labelIndex[label]] = true

proc analyze*(g: Grammar, v: Vocabulary, d: var Diagnostics): Analysis =
  ## Analysis of `g`, which must have passed `checkGrammar` without errors.
  ## Reports left recursion and label problems.
  result = Analysis(g: g, v: v, visible: visibleTokens(g, v),
    predictionCache: newPredictionCache())
  for i, r in g.rules:
    if r.kind == rkParser:
      result.ruleIndex[r.name] = i
      result.parserRules.add i
  result.ruleNullable.setLen g.rules.len
  result.ruleFirst.setLen g.rules.len
  result.computeFirstSets()
  var follow, grammarFollow: Table[GExpr, TokenSet]
  var ruleFollow, ruleGrammarFollow: seq[TokenSet]
  result.computeFollowSets(true, follow, ruleFollow)
  result.computeFollowSets(false, grammarFollow, ruleGrammarFollow)
  result.follow = follow
  result.grammarFollow = grammarFollow
  result.ruleFollow = ruleFollow
  result.assignNames(d)
  result.classify(d)
  result.buildAtn()
  discard result.checkLeftRecursion(d)
