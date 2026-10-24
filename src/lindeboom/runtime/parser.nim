## Parse trees and the parser runtime shared by generated parsers and
## `lindeboom parse`.
##
## A tree has one node type, in the style of the Nim compiler's `PNode`:
## `kind` is the rule or alternative label that produced the node, `sons` are
## its children in input order. Kind 0 is a token, kind 1 an error node: the
## tokens skipped where the parser recovered from a syntax error. `edge` is
## the element label of a node in its parent; label 0 means no label. (It is
## not called `label`, which is a common element label in grammars.)
##
## Adaptive prediction explores alternatives without building parse trees,
## reports failures at the farthest token examined, then parses the selected
## alternative once. Error recovery skips tokens until one can follow a rule
## being parsed, then returns what it has so far. No error is reported until
## a token has been matched since the last one.

import std/[algorithm, hashes, sequtils, sets, strutils, tables]
import ./lexer

export lexer

type
  AtnEdgeKind* = enum
    atEpsilon, atTokens, atCall

  AtnEdgeData* = object
    kind*: AtnEdgeKind
    target*: int
    rule*: int
    tokens*: seq[int]
    minimumPrecedence*: int

  AtnStateData* = object
    edges*: seq[AtnEdgeData]

  AtnDecisionData* = object
    state*: int
    alternatives*: seq[int]
    rule*: int
    alternativeIds*: seq[int]
    minimums*: seq[int]

  AtnRuleData* = object
    start*, stop*: int

  PredictionCache* = ref object
    entries: Table[string, int] ## full-context prediction results
    dfaIndices: Table[DfaKey, int]
    dfaStarts: Table[(int, int), int] ## start state by decision and precedence
    dfaStates: seq[PredictionDfaState]
    gss: Gss
    stopRules: seq[int] ## rule whose stop state each ATN state is, or -1
    follows: seq[seq[(int, bool)]]
      ## return state of each call site of each rule, and whether the call
      ## has precedence 0
    trackWork: bool
    work: int
    fullContextOnly: bool ## skip SLL: every prediction in full context

  SourceText = ref object
    data: string

  ParseNode*[K, L, T] = ref object
    kind*: K            ## `K(0)` for a token, `K(1)` for an error node
    edge*: L            ## element label in the parent, `L(0)` if none
    tok*: LexerToken[T] ## when `kind == K(0)`
    sons*: seq[ParseNode[K, L, T]]
    source: SourceText

  ParseResult*[N] = object
    tree*: N            ## has error nodes if there were syntax errors
    diagnostics*: Diagnostics

  SyntaxError* = object of CatchableError
    pos*: SourcePos

  FollowProc* = proc (rule, kind: int): bool {.closure.}
    ## Whether token kind `kind` can follow rule number `rule`.

  ParserState*[K, L, T] = object
    ## Input of a generated parser: the visible tokens, ending with EOF.
    tokens*: seq[LexerToken[T]]
    i*: int
    source: SourceText
    names: seq[string]      ## token names by kind
    ruleNames: seq[string]  ## rule names by number
    follows: FollowProc
    errors: seq[SyntaxErrorInfo]
    failAt: int             ## farthest token where a match failed
    failExpected: seq[int]  ## token kinds expected there
    rules: seq[int]         ## the rules being parsed, innermost last
    returnStates*: seq[int] ## ATN return state for each active rule call
    precedences*: seq[int]  ## precedence argument for each active rule call
    recovering: bool        ## an error was reported and no token matched since
    reportedAt: int         ## token of the last reported error
    recoveredAt: int        ## token where the last recovery stopped
    recoveredDepth: int     ## rules being parsed then
    fullContext: bool       ## predict in full context only: the retry after
                            ## a syntax error

  TreeNames* = object
    ## Display names by ordinal, for `treeRepr`.
    kinds*, labels*, tokens*: seq[string]

  AtnConfig = object
    state, alternative: int
    stack: int
    precedence: int
    suppressed: bool ## exempt from `precedenceFilter`

  GssNode = object
    returnState, parent, precedence: int

  GssKey = object
    returnState, parent, precedence: int

  Gss = ref object
    ## Call stacks of ATN configurations, as in ANTLR's merged contexts: a
    ## stack is an interned set of frames (id 0 is the bottom of the stack),
    ## so configurations that differ only in their callers share one entry.
    nodes: seq[GssNode]
    indices: Table[GssKey, int]
    sets: seq[seq[int]]
    setIndices: Table[seq[int], int]

  DfaKey = object
    decision, precedence: int
    configs: seq[AtnConfig] ## sorted

  PredictionDfaState = object
    ## A closed set of SLL configurations. A resolved state needs no more
    ## lookahead: its `result` is an alternative, or -2 for a full-context
    ## retry.
    configs: seq[AtnConfig]
    transitions: Table[int, int] ## next state by token kind
    result: int
    resolved: bool

proc report[K, L, T](p: var ParserState[K, L, T])

# ---- tree access ----

func len*[K, L, T](n: ParseNode[K, L, T]): int = n.sons.len

func `[]`*[K, L, T](n: ParseNode[K, L, T], i: int): ParseNode[K, L, T] = n.sons[i]

iterator items*[K, L, T](n: ParseNode[K, L, T]): ParseNode[K, L, T] =
  for x in n.sons: yield x

func son*[K, L, T](n: ParseNode[K, L, T], label: L): ParseNode[K, L, T] =
  ## The first son with `label`, nil if there is none.
  for x in n.sons:
    if x.edge == label: return x

func sonsWith*[K, L, T](n: ParseNode[K, L, T], label: L): seq[ParseNode[K, L, T]] =
  ## All sons with `label`.
  for x in n.sons:
    if x.edge == label: result.add x

func token*[K, L, T](n: ParseNode[K, L, T], kind: T): ParseNode[K, L, T] =
  ## The first son that is a token of `kind`, nil if there is none; for a
  ## token without an element label, as `'virtual'` in `'virtual'? ID`.
  for x in n.sons:
    if x.kind == K(0) and x.tok.kind == kind: return x

func has*[K, L, T](n: ParseNode[K, L, T], kind: T): bool =
  ## Whether a son of `n` is a token of `kind`.
  n.token(kind) != nil

func firstToken[K, L, T](n: ParseNode[K, L, T]): ParseNode[K, L, T] =
  if n.kind == K(0):
    result = n
  else:
    var i = 0
    while result == nil and i < n.sons.len:
      result = n.sons[i].firstToken
      inc i

func lastToken[K, L, T](n: ParseNode[K, L, T]): ParseNode[K, L, T] =
  if n.kind == K(0):
    result = n
  else:
    var i = n.sons.high
    while result == nil and i >= 0:
      result = n.sons[i].lastToken
      dec i

func text*[K, L, T](n: ParseNode[K, L, T]): string =
  ## The source text of `n`, including skipped input between its tokens.
  let a = n.firstToken
  if a != nil:
    result = n.source.data[a.tok.start ..< n.lastToken.tok.stop]

func pos*[K, L, T](n: ParseNode[K, L, T]): SourcePos =
  ## Position of the first token of `n`; line 0 if `n` has no tokens.
  let a = n.firstToken
  if a != nil: result = a.tok.pos

# ---- ASCII art ----

proc addTree[K, L, T](s: var string, n: ParseNode[K, L, T], names: TreeNames,
    prefix: string) =
  if n.kind == K(0):
    let name = names.tokens[ord(n.tok.kind)]
    s.add name
    let text = n.text
    if not name.startsWith('\'') and text.len > 0:
      s.add ' '
      s.addQuoted text
  else:
    s.add names.kinds[ord(n.kind)]
  s.add '\n'
  for i, x in n.sons:
    let last = i == n.sons.high
    s.add prefix & (if last: "└── " else: "├── ")
    if ord(x.edge) != 0: s.add names.labels[ord(x.edge)] & ": "
    s.addTree(x, names, prefix & (if last: "    " else: "│   "))

proc treeRepr*[K, L, T](n: ParseNode[K, L, T], names: TreeNames): string =
  ## `n` as an indented tree, one node per line.
  result.addTree(n, names, "")

func enumNames[E: enum](_: typedesc[E]): seq[string] =
  for x in E: result.add $x

proc treeRepr*[K: enum, L: enum, T: enum](n: ParseNode[K, L, T]): string =
  ## `n` as an indented tree, one node per line, using the enum names.
  n.treeRepr(TreeNames(kinds: enumNames(K), labels: enumNames(L),
    tokens: enumNames(T)))

# ---- parsing ----

func describeToken*(name: string): string =
  ## A token name for an error message.
  if name == "EOF": "end of input" else: name

func describeFound*(name, text: string): string =
  ## The token found, for an error message: its name, with its text unless
  ## the name says it (a literal, EOF) or the text is only white space.
  result = describeToken(name)
  if not name.startsWith('\'') and name != "EOF" and text.strip.len > 0:
    result.add " " & quoteText(text)

func expectedMessage*(expected: openArray[string], found: string): string =
  ## `expected ID, INT or '(' but found ':'`; `found` is as from
  ## `describeFound`.
  result = "expected "
  for i, x in expected:
    if i > 0: result.add(if i == expected.high: " or " else: ", ")
    result.add describeToken(x)
  result.add " but found " & found

func peek*[K, L, T](p: ParserState[K, L, T]): T = p.tokens[p.i].kind

proc newPredictionCache*(trackWork = false,
    fullContextOnly = false): PredictionCache =
  ## `fullContextOnly` predicts in full context without trying SLL first,
  ## which must give the same parses; tests compare the two.
  PredictionCache(entries: initTable[string, int](),
    dfaIndices: initTable[DfaKey, int](), dfaStarts: initTable[(int, int), int](),
    gss: Gss(indices: initTable[GssKey, int](),
      setIndices: initTable[seq[int], int]()), trackWork: trackWork,
    fullContextOnly: fullContextOnly)

func predictionWork*(cache: PredictionCache): int =
  ## Number of ATN configurations processed by predictions using this cache.
  cache.work

func `==`(a, b: AtnConfig): bool =
  a.state == b.state and a.alternative == b.alternative and
    a.stack == b.stack and a.precedence == b.precedence and
    a.suppressed == b.suppressed

func hash(c: AtnConfig): Hash =
  result = hash(c.state)
  result = result !& hash(c.alternative)
  result = result !& hash(c.stack)
  result = result !& hash(c.precedence)
  result = result !& hash(c.suppressed)
  result = !$result

func cmp(a, b: AtnConfig): int =
  cmp((a.state, a.alternative, a.stack, a.precedence, a.suppressed),
    (b.state, b.alternative, b.stack, b.precedence, b.suppressed))

func `==`(a, b: DfaKey): bool =
  a.decision == b.decision and a.precedence == b.precedence and
    a.configs == b.configs

func hash(k: DfaKey): Hash =
  result = hash(k.decision)
  result = result !& hash(k.precedence)
  result = result !& hash(k.configs)
  result = !$result

proc dfaState(cache: PredictionCache, decision, precedence: int,
    configs: seq[AtnConfig]): int =
  ## The state for the closed `configs`, added if it is new.
  let key = DfaKey(decision: decision, precedence: precedence,
    configs: configs.sorted(cmp))
  result = cache.dfaIndices.getOrDefault(key, -1)
  if result < 0:
    result = cache.dfaStates.len
    cache.dfaIndices[key] = result
    cache.dfaStates.add PredictionDfaState(configs: key.configs,
      transitions: initTable[int, int]())

proc resolve(cache: PredictionCache, state, alternative: int) =
  cache.dfaStates[state].resolved = true
  cache.dfaStates[state].result = alternative

func `==`(a, b: GssKey): bool =
  a.returnState == b.returnState and a.parent == b.parent and
    a.precedence == b.precedence

func hash(k: GssKey): Hash =
  result = hash(k.returnState)
  result = result !& hash(k.parent)
  result = result !& hash(k.precedence)
  result = !$result

proc push(gss: Gss, returnState, parent, precedence: int): int =
  let key = GssKey(returnState: returnState, parent: parent, precedence: precedence)
  if key in gss.indices: return gss.indices[key]
  result = gss.nodes.len + 1
  gss.nodes.add GssNode(returnState: returnState, parent: parent,
    precedence: precedence)
  gss.indices[key] = result

proc intern(gss: Gss, frames: seq[int]): int =
  ## Id of the stack made of the sorted `frames`.
  if frames in gss.setIndices: return gss.setIndices[frames]
  gss.sets.add frames
  result = gss.sets.len
  gss.setIndices[frames] = result

proc bottom(gss: Gss): int = gss.intern(@[0])

proc single(gss: Gss, frame: int): int = gss.intern(@[frame])

proc union(gss: Gss, a, b: int): int =
  if a == b: return a
  var merged: seq[int]
  let x = gss.sets[a - 1]
  let y = gss.sets[b - 1]
  var i, j = 0
  while i < x.len or j < y.len:
    if j == y.len or (i < x.len and x[i] < y[j]):
      merged.add x[i]
      inc i
    elif i == x.len or y[j] < x[i]:
      merged.add y[j]
      inc j
    else:
      merged.add x[i]
      inc i
      inc j
  gss.intern(merged)

proc atnClosure(seed: seq[AtnConfig], states: openArray[AtnStateData],
    rules: openArray[AtnRuleData], stopRules: openArray[int],
    follows: openArray[seq[(int, bool)]], gss: Gss,
    cache: PredictionCache = nil, precedenceRule = -1): seq[AtnConfig] =
  ## With `follows` (SLL), a configuration that leaves its rule with an
  ## empty stack also goes on at every call site of the rule. One that
  ## leaves `precedenceRule` through a call of precedence 0 is `suppressed`.
  # `seq` assignment aliases its backing storage. DFA transitions feed cached
  # configuration sets back into closure, so the work queue must own its copy.
  var queue = @seed
  # Configurations that differ only in their stack are merged into one with
  # the union of the stacks; a config is expanded again when its stack grows.
  var current = initTable[(int, int, int, bool), int]()
  var order: seq[(int, int, int, bool)]
  var i = 0
  while i < queue.len:
    var c = queue[i]
    inc i
    if cache != nil and cache.trackWork: inc cache.work
    let key = (c.state, c.alternative, c.precedence, c.suppressed)
    if key in current:
      let merged = gss.union(current[key], c.stack)
      if merged == current[key]: continue
      c.stack = merged
    else:
      order.add key
    current[key] = c.stack
    if c.state < 0: continue
    let rule = stopRules[c.state]
    if rule >= 0:
      for frameId in gss.sets[c.stack - 1]:
        var next = c
        if frameId > 0:
          let frame = gss.nodes[frameId - 1]
          next.stack = frame.parent
          next.state = frame.returnState
          next.precedence = frame.precedence
        else:
          next.stack = gss.bottom
          next.state = -1
          if follows.len > 0:
            # The caller is unknown: its precedence too, so allow every one.
            for (returnState, outermost) in follows[rule]:
              queue.add AtnConfig(state: returnState,
                alternative: c.alternative, stack: gss.bottom, precedence: 0,
                suppressed: c.suppressed or
                  (outermost and rule == precedenceRule))
        queue.add next
      continue
    for edge in states[c.state].edges:
      case edge.kind
      of atEpsilon:
        if edge.minimumPrecedence < 0 or c.precedence <= edge.minimumPrecedence:
          var next = c
          next.state = edge.target
          queue.add next
      of atCall:
        var next = c
        next.state = rules[edge.rule].start
        next.stack = gss.single(gss.push(edge.target, c.stack, c.precedence))
        next.precedence = edge.minimumPrecedence
        queue.add next
      of atTokens:
        discard
  for key in order:
    result.add AtnConfig(state: key[0], alternative: key[1], precedence: key[2],
      suppressed: key[3], stack: current[key])

proc conflicting(configs: openArray[AtnConfig]): bool =
  ## ANTLR's termination test: every (state, context) is reachable through
  ## several alternatives and no state belongs to a single alternative, so
  ## more lookahead cannot separate them.
  var byContext = initTable[(int, int, int), HashSet[int]]()
  var byState = initTable[int, HashSet[int]]()
  for c in configs:
    byContext.mgetOrPut((c.state, c.stack, c.precedence),
      initHashSet[int]()).incl c.alternative
    byState.mgetOrPut(c.state, initHashSet[int]()).incl c.alternative
  if byContext.len == 0: return false
  for alts in byContext.values:
    if alts.len < 2: return false
  for alts in byState.values:
    if alts.len < 2: return false
  true

proc expectedAtn(configs: openArray[AtnConfig], states: openArray[AtnStateData]): seq[int] =
  var expected = initHashSet[int]()
  for c in configs:
    if c.state >= 0:
      for edge in states[c.state].edges:
        if edge.kind == atTokens:
          for kind in edge.tokens: expected.incl kind
  result = toSeq(expected.items)
  result.sort()

proc prepare(cache: PredictionCache, states: openArray[AtnStateData],
    rules: openArray[AtnRuleData]) =
  ## Fills in the rule whose stop state each ATN state is, and the return
  ## states of each rule's call sites.
  if cache.stopRules.len != states.len:
    cache.stopRules = newSeq[int](states.len)
    for id in cache.stopRules.mitems: id = -1
    for rule, info in rules:
      if info.start != info.stop: cache.stopRules[info.stop] = rule
    cache.follows = newSeq[seq[(int, bool)]](rules.len)
    for state in states:
      for edge in state.edges:
        let follow = (edge.target, edge.minimumPrecedence == 0)
        if edge.kind == atCall and follow notin cache.follows[edge.rule]:
          cache.follows[edge.rule].add follow

func seed(d: AtnDecisionData, stack, precedence: int): seq[AtnConfig] =
  ## One configuration per alternative of `d` that `precedence` allows.
  for position, state in d.alternatives:
    let minimum = if position < d.minimums.len: d.minimums[position] else: -1
    if minimum >= 0 and precedence > minimum: continue
    let alternative = if position < d.alternativeIds.len:
      d.alternativeIds[position] else: position
    result.add AtnConfig(state: state, alternative: alternative,
      stack: stack, precedence: precedence)

func precedenceFilter(configs: seq[AtnConfig]): seq[AtnConfig] =
  ## As ANTLR's `applyPrecedenceFilter`, for the start state of a precedence
  ## loop: the exit's global FOLLOW leads back into a caller's loop of the
  ## same rule, so a configuration of the exit that meets an operator
  ## alternative's in the same state and context is dropped. This makes the
  ## loop greedy, as full context does by taking the lowest alternative.
  ## A `suppressed` one is kept: it left through a call of precedence 0,
  ## which may continue inside an operator alternative of an outer loop, as
  ## the middle `e` of `e : e (',' e)* '>>' e | ID ;` does.
  var continuing = initHashSet[(int, int)]()
  for c in configs:
    if c.alternative != high(int): continuing.incl (c.state, c.stack)
  for c in configs:
    if c.alternative != high(int) or c.suppressed or
        (c.state, c.stack) notin continuing:
      result.add c

proc sllTarget(cache: PredictionCache, source, kind: int,
    d: AtnDecisionData, decision, precedence: int,
    states: openArray[AtnStateData], rules: openArray[AtnRuleData]): int =
  ## The DFA state after token `kind` in `source`, computed over the ATN
  ## and added with its edge.
  var next: seq[AtnConfig]
  for c in cache.dfaStates[source].configs:
    if c.state < 0: continue
    for edge in states[c.state].edges:
      if edge.kind == atTokens and kind in edge.tokens:
        var advanced = c
        advanced.state = edge.target
        next.add advanced
  if next.len == 0:
    # No viable alternative. A loop exit is the useful recovery choice when
    # the caller's continuation cannot match: let the real parser report and
    # recover at that call site instead of turning prediction failure into a
    # nested rule error. Otherwise full context reports the error.
    result = cache.dfaState(decision, precedence, @[])
    cache.resolve(result, if high(int) in d.alternativeIds: high(int) else: -2)
  else:
    let configs = atnClosure(next, states, rules, cache.stopRules,
      cache.follows, cache.gss, cache)
    result = cache.dfaState(decision, precedence, configs)
    var survivors = initHashSet[int]()
    for c in configs: survivors.incl c.alternative
    if survivors.len > 1 and conflicting(configs):
      cache.resolve(result, -2)
    elif survivors.len == 1:
      for alternative in survivors: cache.resolve(result, alternative)
  cache.dfaStates[source].transitions[kind] = result

proc predictSll[K, L, T](p: ParserState[K, L, T], decision: int,
    states: openArray[AtnStateData], decisions: openArray[AtnDecisionData],
    rules: openArray[AtnRuleData], cache: PredictionCache, precedence: int): int =
  ## Predicts in local context by walking the decision's DFA, extending it
  ## over the ATN where an edge is missing. -2 means a full-context retry.
  let d = decisions[decision]
  cache.prepare(states, rules)
  var s = cache.dfaStarts.getOrDefault((decision, precedence), -1)
  if s < 0:
    let isPrecedence = high(int) in d.alternativeIds and d.minimums.len > 0
    var configs = atnClosure(d.seed(cache.gss.bottom, precedence), states,
      rules, cache.stopRules, cache.follows, cache.gss, cache,
      if isPrecedence: d.rule else: -1)
    if isPrecedence: configs = precedenceFilter(configs)
    s = cache.dfaState(decision, precedence, configs)
    cache.dfaStarts[(decision, precedence)] = s
  var offset = p.i
  while not cache.dfaStates[s].resolved:
    let kind = ord(p.tokens[offset].kind)
    if kind == 0:
      # At the end of the input only the alternatives that left the rule
      # are left; one of them, or a retry.
      var accepted = initHashSet[int]()
      for c in cache.dfaStates[s].configs:
        if c.state < 0: accepted.incl c.alternative
      if accepted.len != 1: return -2
      for alternative in accepted.items: return alternative
    var target = cache.dfaStates[s].transitions.getOrDefault(kind, -1)
    if target < 0:
      target = cache.sllTarget(s, kind, d, decision, precedence, states, rules)
    s = target
    inc offset
  cache.dfaStates[s].result

proc predictLl[K, L, T](p: var ParserState[K, L, T], decision: int,
    states: openArray[AtnStateData], decisions: openArray[AtnDecisionData],
    rules: openArray[AtnRuleData], cache: PredictionCache = nil,
    precedence = 0): int =
  ## Predicts in the context of the active parser call stack.
  let d = decisions[decision]
  var activeCache = cache
  if activeCache == nil: activeCache = newPredictionCache()
  activeCache.prepare(states, rules)
  let gss = activeCache.gss
  template stopRules: untyped = activeCache.stopRules
  var context = gss.bottom
  for i, returnState in p.returnStates:
    # On return from this frame, restore the caller's precedence. The
    # current frame's precedence applies only while executing this rule.
    let callerPrecedence = if i > 0: p.precedences[i - 1] else: p.precedences[i]
    context = gss.single(gss.push(returnState, context, callerPrecedence))
  var configs = d.seed(context, precedence)
  var offset = p.i
  var key = $decision & ":" & $precedence & ":true:"
  for i, state in p.returnStates:
    key.add $state & ":" & $p.precedences[i] & ","
  key.add "|"
  while true:
    let kind = ord(p.tokens[offset].kind)
    key.add $kind & ","
    if cache != nil and cache.entries.hasKey(key):
      return cache.entries[key]
    configs = atnClosure(configs, states, rules, stopRules, [], gss, cache)
    if kind == 0:
      var accepted = high(int)
      var hasAccepted = false
      for c in configs:
        if c.state < 0:
          accepted = min(accepted, c.alternative)
          hasAccepted = true
      if hasAccepted:
        if cache != nil: cache.entries[key] = accepted
        return accepted
    let expected = expectedAtn(configs, states)
    var next: seq[AtnConfig]
    for c in configs:
      if c.state < 0: continue
      for edge in states[c.state].edges:
        if edge.kind == atTokens and kind in edge.tokens:
          var advanced = c
          advanced.state = edge.target
          next.add advanced
    if next.len == 0:
      # A loop exit is the useful recovery choice, as in `sllTarget`.
      for alternative in d.alternativeIds:
        if alternative == high(int):
          return alternative
      if expected.len == 0: p.failPrediction(offset, [0])
      p.failPrediction(offset, expected)
    configs = atnClosure(next, states, rules, stopRules, [], gss, cache)
    var survivors = initHashSet[int]()
    for c in configs: survivors.incl c.alternative
    if survivors.len > 1 and conflicting(configs):
      let lowest = min(toSeq(survivors.items))
      if cache != nil: cache.entries[key] = lowest
      return lowest
    if survivors.len == 1 and kind != 0:
      for alternative in survivors.items:
        if cache != nil: cache.entries[key] = alternative
        return alternative
    if kind == 0:
      var accepted = high(int)
      var hasAccepted = false
      for c in configs:
        if c.state < 0:
          accepted = min(accepted, c.alternative)
          hasAccepted = true
      if hasAccepted:
        if cache != nil: cache.entries[key] = accepted
        return accepted
      p.failPrediction(offset, expectedAtn(configs, states))
    inc offset

proc predict*[K, L, T](p: var ParserState[K, L, T], decision: int,
    states: openArray[AtnStateData], decisions: openArray[AtnDecisionData],
    rules: openArray[AtnRuleData], cache: PredictionCache = nil,
    precedence = 0): int =
  ## SLL first; retry with the active parser call stack when local context
  ## leaves multiple alternatives or cannot find a viable alternative.
  if p.fullContext or (cache != nil and cache.fullContextOnly):
    return p.predictLl(decision, states, decisions, rules, cache, precedence)
  let sllCache = if cache != nil: cache else: newPredictionCache()
  result = p.predictSll(decision, states, decisions, rules, sllCache, precedence)
  if result == -2:
    result = p.predictLl(decision, states, decisions, rules, cache, precedence)

proc failPrediction*[K, L, T](p: var ParserState[K, L, T], at: int,
    expected: openArray[int]) {.noreturn.} =
  ## Reports a no-viable-alternative failure at the farthest token examined.
  if at > p.failAt:
    p.failAt = at
    p.failExpected.setLen 0
  if at == p.failAt:
    for kind in expected:
      if kind notin p.failExpected: p.failExpected.add kind
  p.report()
  raise (ref SyntaxError)(msg: "syntax error", pos: p.tokens[p.i].pos)

proc newNode*[K, L, T](p: ParserState[K, L, T], kind: K): ParseNode[K, L, T] =
  ParseNode[K, L, T](kind: kind, source: p.source)

proc add*[K, L, T](n, son: ParseNode[K, L, T], label = L(0)) =
  son.edge = label
  n.sons.add son

proc wrap*[K, L, T](p: ParserState[K, L, T], left: ParseNode[K, L, T], kind: K,
    label = L(0)): ParseNode[K, L, T] =
  ## A new node of `kind` with `left` as its first son, for an operator that
  ## follows the expression `left`.
  result = p.newNode(kind)
  result.add(left, label)

proc take*[K, L, T](p: var ParserState[K, L, T], n: ParseNode[K, L, T],
    label = L(0)) =
  ## Adds the current token to `n` and moves past it. EOF is not added and
  ## stays current.
  if p.tokens[p.i].kind != T(0):
    n.add(ParseNode[K, L, T](kind: K(0), tok: p.tokens[p.i], source: p.source),
      label)
    inc p.i
  p.recovering = false

proc expect*[K, L, T, S](p: var ParserState[K, L, T], expected: S) =
  ## Notes that one of the `expected` token kinds was needed, or could have
  ## gone on, at the current token; if parsing fails there they are in the
  ## message. The error that is reported is the one at the farthest token,
  ## which after prediction need not be the last one.
  if p.i > p.failAt:
    p.failAt = p.i
    p.failExpected.setLen 0
  if p.i == p.failAt:
    for x in expected:
      if ord(x) notin p.failExpected: p.failExpected.add ord(x)

proc report[K, L, T](p: var ParserState[K, L, T]) =
  ## Reports the farthest failure, unless the parser is still recovering
  ## from an error there or before. Expected tokens are listed by kind, with
  ## EOF last.
  if not p.recovering and p.failAt > p.reportedAt:
    var kinds = p.failExpected
    kinds.sort()
    var e = SyntaxErrorInfo(hasToken: true)
    for k in kinds:
      if k != 0: e.expected.add k
    if 0 in kinds: e.expected.add 0
    let found = p.tokens[p.failAt]
    e.pos = found.pos
    e.found = ord(found.kind)
    e.text = found.text(p.source.data)
    for r in p.rules: e.rules.add p.ruleNames[r]
    var expected: seq[string]
    for k in e.expected: expected.add p.names[k]
    e.msg = expectedMessage(expected, describeFound(p.names[e.found], e.text))
    p.errors.add e
    p.reportedAt = p.failAt
  p.recovering = true
  p.failAt = -1
  p.failExpected.setLen 0

proc fail*[K, L, T, S](p: var ParserState[K, L, T], expected: S) {.noreturn.} =
  ## Fails to match one of the `expected` token kinds at the current token.
  ## Reports the error; the rule recovers from it.
  p.expect(expected)
  p.report()
  raise (ref SyntaxError)(msg: "syntax error", pos: p.tokens[p.i].pos)

proc canFollow[K, L, T](p: ParserState[K, L, T], kind: T): bool =
  ## Whether `kind` is EOF or can follow one of the rules being parsed.
  result = kind == T(0)
  for r in p.rules:
    if p.follows(r, ord(kind)): result = true

proc skip[K, L, T](p: var ParserState[K, L, T], err: ParseNode[K, L, T]) =
  ## Adds the current token to the error node `err` and moves past it.
  err.sons.add ParseNode[K, L, T](kind: K(0), tok: p.tokens[p.i], source: p.source)
  inc p.i

proc errorNode[K, L, T](p: ParserState[K, L, T]): ParseNode[K, L, T] =
  p.newNode(K(1))

proc enter*[K, L, T](p: var ParserState[K, L, T], rule: int, returnState = -1,
    precedence = 0) =
  ## Starts parsing rule number `rule`; `returnState` identifies its ATN
  ## call-site continuation, or -1 for the start rule.
  p.rules.add rule
  p.returnStates.add returnState
  p.precedences.add precedence

proc leave*[K, L, T](p: var ParserState[K, L, T]) =
  ## Ends the innermost rule.
  discard p.rules.pop()
  discard p.returnStates.pop()
  discard p.precedences.pop()

proc recover*[K, L, T](p: var ParserState[K, L, T], n: var ParseNode[K, L, T]) =
  ## After a syntax error in the innermost rule, whose node so far is `n`
  ## (nil if there is none yet): skips tokens until one that can follow a rule being parsed,
  ## into an error node added to `n`.
  let err = p.errorNode
  # recovering again where the last recovery stopped, in a rule at least as
  # deep, would not make progress
  if p.i == p.recoveredAt and p.rules.len >= p.recoveredDepth and p.peek != T(0):
    p.skip(err)
  while not p.canFollow(p.peek): p.skip(err)
  p.recoveredAt = p.i
  p.recoveredDepth = p.rules.len
  if n == nil: n = err
  else: n.add err

proc more*[K, L, T, S](p: var ParserState[K, L, T], n: ParseNode[K, L, T],
    first, follow: S): bool =
  ## Whether a loop whose body starts with `first` and that is followed by
  ## `follow` goes on. A token in neither is an error:
  ## tokens are skipped into an error node added to `n` until one that is,
  ## or that can follow a rule being parsed. EOF just ends the loop, so
  ## `follow` need not have the EOF that can follow a start rule. When the
  ## loop ends, `first` is expected at the current token.
  result = p.peek in first
  if not result: p.expect(first)
  if not result and p.peek notin follow and p.peek != T(0):
    p.expect(follow)
    p.report()
    let err = p.errorNode
    while p.peek notin first and p.peek notin follow and not p.canFollow(p.peek):
      p.skip(err)
    n.add err
    result = p.peek in first

proc match*[K, L, T](p: var ParserState[K, L, T], n: ParseNode[K, L, T],
    kind: T, label = L(0)) =
  if p.peek != kind: p.fail({kind})
  p.take(n, label)

proc matchSet*[K, L, T](p: var ParserState[K, L, T], n: ParseNode[K, L, T],
    kinds: set[T], label = L(0)) =
  if p.peek notin kinds: p.fail(kinds)
  p.take(n, label)

proc initParserState*[K, L, T](tokens: seq[LexerToken[T]], src: string,
    names, ruleNames: seq[string], follows: FollowProc): ParserState[K, L, T] =
  ## `tokens` from `tokenize`, hidden tokens are dropped. `names` are the
  ## token names by kind and `ruleNames` the rule names by number, for
  ## messages.
  result.source = SourceText(data: src)
  result.names = names
  result.ruleNames = ruleNames
  result.follows = follows
  result.failAt = -1
  result.reportedAt = -1
  result.recoveredAt = -1
  for t in tokens:
    if not t.hidden: result.tokens.add t

proc skipRest[K, L, T](p: var ParserState[K, L, T], n: ParseNode[K, L, T]) =
  ## After the start rule, whose node is `n`: any input left is an error, and
  ## is skipped into an error node.
  if p.peek != T(0):
    p.expect([0])
    p.report()
    let err = p.errorNode
    while p.peek != T(0): p.skip(err)
    n.add err

proc retryInFullContext*[K, L, T](p: var ParserState[K, L, T],
    n: ParseNode[K, L, T]): bool =
  ## After the start rule, whose node is `n`: whether to parse again from
  ## the first token, in full context. SLL prediction can choose an
  ## alternative before full context would see a syntax error, so with an
  ## error the parse is redone, as in ANTLR's two-stage parsing, and errors
  ## and recovery are those of full context. `p` is then reset for it.
  p.skipRest(n)
  if p.errors.len == 0 or p.fullContext: return false
  var tokens = move p.tokens
  p = initParserState[K, L, T](@[], p.source.data, p.names, p.ruleNames,
    p.follows)
  p.tokens = move tokens
  p.fullContext = true
  true

proc finish*[K, L, T](p: var ParserState[K, L, T], n: ParseNode[K, L, T],
    d: var Diagnostics) =
  ## After the start rule, whose node is `n`, and `retryInFullContext`: any
  ## input left is an error, and is skipped into an error node. Adds the
  ## syntax errors to `d`.
  p.skipRest(n)
  for e in p.errors: d.syntaxError(e)

proc runParser*[K, L, T](tokens: seq[LexerToken[T]], src: string,
    d: var Diagnostics, ruleNames: seq[string], follows: FollowProc,
    rule: proc (p: var ParserState[K, L, T]): ParseNode[K, L, T] {.nimcall.}):
    ParseNode[K, L, T] =
  ## Parses `tokens` with `rule`, which must be followed by the end of the
  ## input. Syntax errors are added to `d`; the tree has error nodes where
  ## the parser recovered from them.
  var p = initParserState[K, L, T](tokens, src, enumNames(T), ruleNames, follows)
  result = rule(p)
  if p.retryInFullContext(result): result = rule(p)
  p.finish(result, d)
