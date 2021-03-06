import strformat, tables, algorithm, sets, sequtils

type
  # facts
  Field* = enum
    Identifier, Attribute, Value
  Fact[T] = tuple[id: T, attr: T, value: T]
  TokenKind = enum
    Insert, Retract, Update
  Token[T] = object
    fact: Fact[T]
    case kind: TokenKind
    of Insert, Retract:
      nil
    of Update:
      oldFact: Fact[T]
  IdAttr = tuple[id: int, attr: int]

  # vars
  Vars[T] = Table[string, T]
  Var* = object
    name*: string
    field: Field

  # functions
  CallbackFn[T] = proc (vars: Vars[T])
  SessionCallbackFn[T] = proc (session: var Session[T], vars: Vars[T])
  QueryFn[T, U] = proc (vars: Vars[T]): U
  FilterFn[T] = proc (vars: Vars[T]): bool

  # alpha network
  AlphaNode[T] = ref object
    testField: Field
    testValue: T
    facts: Table[int, Table[int, Fact[T]]]
    successors: seq[JoinNode[T]]
    children: seq[AlphaNode[T]]

  # beta network
  MemoryNodeType = enum
    Root, Partial, Prod
  MemoryNode[T] = ref object
    parent: JoinNode[T]
    child: JoinNode[T]
    vars: seq[Vars[T]]
    idAttrs: seq[IdAttr]
    enabledVars: seq[bool]
    condition: Condition[T]
    case nodeType: MemoryNodeType
      of Prod:
        callback: CallbackFn[T]
        trigger: bool
        thenQueue: seq[bool]
        filter: FilterFn[T]
      else:
        nil
    when defined(pararulesTest):
      debugFacts*: seq[seq[Fact[T]]]
  JoinNode[T] = ref object
    parent: MemoryNode[T]
    child: MemoryNode[T]
    alphaNode: AlphaNode[T]
    condition: Condition[T]
    prodNode: MemoryNode[T]
    idName: string
    disableFastUpdates: bool

  # session
  Condition[T] = object
    nodes: seq[AlphaNode[T]]
    vars: seq[Var]
    shouldTrigger: bool
  Production*[T, U] = object
    callback: SessionCallbackFn[T]
    conditions: seq[Condition[T]]
    query: QueryFn[T, U]
    name: string
    filter: FilterFn[T]
  Session*[T] = object
    alphaNode: AlphaNode[T]
    betaNode: MemoryNode[T]
    prodNodes*: ref Table[string, MemoryNode[T]]
    idAttrNodes: ref Table[IdAttr, HashSet[ptr AlphaNode[T]]]
    insideRule*: bool
    thenNodes: ref HashSet[ptr MemoryNode[T]]

proc getParent*(node: MemoryNode): MemoryNode =
  node.parent.parent

proc addNode(node: AlphaNode, newNode: AlphaNode): AlphaNode =
  for child in node.children:
    if child.testField == newNode.testField and child.testValue == newNode.testValue:
      return child
  node.children.add(newNode)
  return newNode

proc addNodes(session: Session, nodes: seq[AlphaNode]): AlphaNode =
  result = session.alphaNode
  for node in nodes:
    result = result.addNode(node)

proc add*[T, U](production: var Production[T, U], id: Var or T, attr: T, value: Var or T, then: bool) =
  var condition = Condition[T](shouldTrigger: then)
  for fieldType in [Field.Identifier, Field.Attribute, Field.Value]:
    case fieldType:
      of Field.Identifier:
        when id is T:
          condition.nodes.add AlphaNode[T](testField: fieldType, testValue: id)
        else:
          var temp = id
          temp.field = fieldType
          condition.vars.add(temp)
      of Field.Attribute:
        condition.nodes.add AlphaNode[T](testField: fieldType, testValue: attr)
      of Field.Value:
        when value is T:
          condition.nodes.add AlphaNode[T](testField: fieldType, testValue: value)
        else:
          var temp = value
          temp.field = fieldType
          condition.vars.add(temp)
  production.conditions.add(condition)

proc isAncestor(x, y: JoinNode): bool =
  var node = y
  while node != nil and node.parent != nil:
    if node.parent.parent == x:
      return true
    else:
      node = node.parent.parent
  false

proc add*[T, U](session: Session[T], production: Production[T, U]) =
  var memNode = session.betaNode
  var joinNodes: seq[JoinNode[T]]
  let last = production.conditions.len - 1
  var
    bindings: HashSet[string]
    joinedBindings: HashSet[string]
  for i in 0 .. last:
    var condition = production.conditions[i]
    var leafNode = session.addNodes(condition.nodes)
    var joinNode = JoinNode[T](parent: memNode, alphaNode: leafNode, condition: condition)
    for v in condition.vars:
      if bindings.contains(v.name):
        joinedBindings.incl(v.name)
        if v.field == Identifier:
          joinNode.idName = v.name
      else:
        bindings.incl(v.name)
    memNode.child = joinNode
    leafNode.successors.add(joinNode)
    # successors must be sorted by ancestry (descendents first) to avoid duplicate rule firings
    leafNode.successors.sort(proc (x, y: JoinNode[T]): int =
      if isAncestor(x, y): 1 else: -1)
    var newMemNode = MemoryNode[T](parent: joinNode, nodeType: if i == last: Prod else: Partial, condition: condition)
    if newMemNode.nodeType == Prod:
      newMemNode.filter = production.filter
      if production.callback != nil:
        var sess = session
        newMemNode.callback = proc (vars: Vars[T]) = production.callback(sess, vars)
      if session.prodNodes.hasKey(production.name):
        raise newException(Exception, production.name & " already exists in session")
      session.prodNodes[production.name] = newMemNode
    joinNodes.add(joinNode)
    joinNode.child = newMemNode
    memNode = newMemNode
  for node in joinNodes:
    node.prodNode = memNode
    # disable fast updates for facts whose value is part of a join
    for v in node.condition.vars:
      if v.field == Value and joinedBindings.contains(v.name):
        node.disableFastUpdates = true
        break

proc getVarsFromFact[T](vars: var Vars[T], condition: Condition[T], fact: Fact[T]): bool =
  for v in condition.vars:
    case v.field:
      of Identifier:
        if vars.hasKey(v.name) and vars[v.name].type0 != fact[0].type0:
          return false
        else:
          vars[v.name] = fact[0]
      of Attribute:
        raise newException(Exception, "Attributes can not contain vars: " & $v)
      of Value:
        if vars.hasKey(v.name) and vars[v.name] != fact[2]:
          return false
        else:
          vars[v.name] = fact[2]
  true

proc performJoinTests(node: JoinNode, vars: var Vars, alphaFact: Fact): bool =
  if not vars.getVarsFromFact(node.condition, alphaFact):
    return false
  true

proc leftActivation[T](session: var Session[T], node: var MemoryNode[T], vars: Vars[T], debugFacts: ref seq[Fact[T]], token: Token[T])

proc leftActivation[T](session: var Session[T], node: JoinNode[T], vars: Vars[T], debugFacts: ref seq[Fact[T]], token: Token[T]) =
  # SHORTCUT: if we know the id, only loop over alpha facts with that id
  if node.idName != "":
    let id = vars[node.idName].type0
    if node.alphaNode.facts.hasKey(id):
      for alphaFact in node.alphaNode.facts[id].values:
        var newVars = vars
        if performJoinTests(node, newVars, alphaFact):
          var newToken = token
          newToken.fact = alphaFact
          session.leftActivation(node.child, newVars, debugFacts, newToken)
  else:
    for factsForId in node.alphaNode.facts.values:
      for alphaFact in factsForId.values:
        var newVars = vars
        if performJoinTests(node, newVars, alphaFact):
          var newToken = token
          newToken.fact = alphaFact
          session.leftActivation(node.child, newVars, debugFacts, newToken)

proc leftActivation[T](session: var Session[T], node: var MemoryNode[T], vars: Vars[T], debugFacts: ref seq[Fact[T]], token: Token[T]) =
  let id = token.fact.id.type0
  let attr = token.fact.attr.type1.ord
  let idAttr = (id, attr)

  case token.kind:
  of Insert:
    node.vars.add(vars)
    let enabled = node.nodeType != Prod or node.filter == nil or node.filter(vars)
    node.enabledVars.add(enabled)
    when defined(pararulesTest):
      debugFacts[].add(token.fact)
      node.debugFacts.add(debugFacts[])
    if node.nodeType == Prod and node.callback != nil:
      let trigger = node.trigger and enabled
      node.thenQueue.add(trigger)
      if trigger:
        session.thenNodes[].incl(node.addr)
    node.idAttrs.add(idAttr)
  of Retract:
    let index = node.idAttrs.find(idAttr)
    node.vars.delete(index)
    node.enabledVars.delete(index)
    when defined(pararulesTest):
      node.debugFacts.delete(index)
    if node.nodeType == Prod and node.callback != nil:
      node.thenQueue.delete(index)
    node.idAttrs.delete(index)
  of Update:
    let index = node.idAttrs.find(idAttr)
    node.vars[index] = vars
    let enabled = node.nodeType != Prod or node.filter == nil or node.filter(vars)
    node.enabledVars[index] = enabled
    when defined(pararulesTest):
      debugFacts[].add(token.fact)
      node.debugFacts[index] = debugFacts[]
    if node.nodeType == Prod and node.callback != nil:
      let trigger = node.trigger and enabled
      node.thenQueue[index] = trigger
      if trigger:
        session.thenNodes[].incl(node.addr)

  if node.nodeType != Prod:
    session.leftActivation(node.child, vars, debugFacts, token)

proc rightActivation[T](session: var Session[T], node: JoinNode[T], token: Token[T]) =
  if (token.kind == Insert or token.kind == Update) and node.condition.shouldTrigger:
    node.prodNode.trigger = true
  when defined(pararulesTest):
    proc newRefSeq[T](s: seq[T]): ref seq[T] =
      new(result)
      result[] = s
  if node.parent.nodeType == Root:
    var vars = Vars[T]()
    if performJoinTests(node, vars, token.fact):
      let debugFacts: ref seq[Fact[T]] =
        when defined(pararulesTest):
          newRefSeq(newSeq[Fact[T]]())
        else:
          nil
      session.leftActivation(node.child, vars, debugFacts, token)
  else:
    for i in 0 ..< node.parent.vars.len:
      let vars = node.parent.vars[i]
      # SHORTCUT: if we know the id, compare it with the token right away
      if node.idName != "" and vars[node.idName].type0 != token.fact.id.type0:
        continue
      var newVars = vars # making a mutable copy here is far faster than making `vars` mutable above
      if performJoinTests(node, newVars, token.fact):
        let debugFacts: ref seq[Fact[T]] =
          when defined(pararulesTest):
            newRefSeq(node.parent.debugFacts[i])
          else:
            nil
        session.leftActivation(node.child, newVars, debugFacts, token)

proc rightActivation[T](session: var Session[T], node: var AlphaNode[T], token: Token[T]) =
  let id = token.fact.id.type0
  let attr = token.fact.attr.type1.ord
  let idAttr = (id, attr)
  case token.kind:
  of Insert:
    if not node.facts.hasKey(id):
      node.facts[id] = initTable[int, Fact[T]]()
    node.facts[id][attr] = token.fact
    if not session.idAttrNodes.hasKey(idAttr):
      session.idAttrNodes[idAttr] = initHashSet[ptr AlphaNode[T]](initialSize = 4)
    let exists = session.idAttrNodes[idAttr].containsOrIncl(node.addr)
    assert not exists
  of Retract:
    node.facts[id].del(attr)
    let missing = session.idAttrNodes[idAttr].missingOrExcl(node.addr)
    assert not missing
  of Update:
    assert node.facts[id][attr] == token.oldFact
    node.facts[id][attr] = token.fact
  for child in node.successors:
    if token.kind == Update and child.disableFastUpdates:
      session.rightActivation(child, Token[T](fact: token.oldFact, kind: Retract))
      session.rightActivation(child, Token[T](fact: token.fact, kind: Insert))
    else:
      session.rightActivation(child, token)

proc triggerThenBlocks[T](session: var Session[T]) =
  # find all nodes with `then` blocks that need executed
  var thenNodes: seq[ptr MemoryNode[T]]
  for node in session.thenNodes[].items:
    thenNodes.add(node)
  if thenNodes.len == 0:
    return
  session.thenNodes[].clear
  # collect all nodes/vars to be executed
  var thenQueue: seq[(MemoryNode[T], Vars[T])]
  for node in thenNodes:
    node.trigger = false
    for i in 0 ..< node.thenQueue.len:
      if node.thenQueue[i]:
        thenQueue.add((node: node[], vars: node.vars[i]))
        node.thenQueue[i] = false
  # execute `then` blocks
  for (node, vars) in thenQueue:
    node.callback(vars)
  # recur because there may be new `then` blocks to execute
  session.triggerThenBlocks()

proc getAlphaNodesForFact[T](session: var Session[T], node: var AlphaNode[T], fact: Fact[T], root: bool, nodes: var HashSet[ptr AlphaNode[T]]) =
  if root:
    for child in node.children.mitems:
      session.getAlphaNodesForFact(child, fact, false, nodes)
  else:
    let val = case node.testField:
      of Field.Identifier: fact[0]
      of Field.Attribute: fact[1]
      of Field.Value: fact[2]
    if val != node.testValue:
      return
    nodes.incl(node.addr)
    for child in node.children.mitems:
      session.getAlphaNodesForFact(child, fact, false, nodes)

proc upsertFact[T](session: var Session[T], fact: Fact[T], nodes: HashSet[ptr AlphaNode[T]]) =
  let id = fact.id.type0
  let attr = fact.attr.type1.ord
  let idAttr = (id, attr)
  if not session.idAttrNodes.hasKey(idAttr):
    for n in nodes.items:
      session.rightActivation(n[], Token[T](fact: fact, kind: Insert))
  else:
    let existingNodes = session.idAttrNodes[idAttr]
    # retract any facts from nodes that the new fact wasn't inserted in
    # we use toSeq here to make a copy of the existingNodes, because
    # rightActivation will modify it
    for n in existingNodes.items.toSeq:
      if not nodes.contains(n):
        let oldFact = n.facts[fact.id.type0][fact.attr.type1.ord]
        session.rightActivation(n[], Token[T](fact: oldFact, kind: Retract))
    # update or insert facts, depending on whether the node already exists
    for n in nodes.items:
      if existingNodes.contains(n):
        let oldFact = n.facts[fact.id.type0][fact.attr.type1.ord]
        session.rightActivation(n[], Token[T](fact: fact, kind: Update, oldFact: oldFact))
      else:
        session.rightActivation(n[], Token[T](fact: fact, kind: Insert))

proc insertFact*[T](session: var Session[T], fact: Fact[T]) =
  var nodes = initHashSet[ptr AlphaNode[T]](initialSize = 4)
  getAlphaNodesForFact(session, session.alphaNode, fact, true, nodes)
  session.upsertFact(fact, nodes)
  if not session.insideRule:
    session.triggerThenBlocks()

proc retractFact*[T](session: var Session[T], fact: Fact[T]) =
  let id = fact.id.type0
  let attr = fact.attr.type1.ord
  let idAttr = (id, attr)
  # we use toSeq here to make a copy of idAttrNodes[idAttr], since
  # rightActivation will modify it
  for node in session.idAttrNodes[idAttr].items.toSeq:
    assert fact == node.facts[id][attr]
    session.rightActivation(node[], Token[T](fact: fact, kind: Retract))

proc initSession*[T](): Session[T] =
  result.alphaNode = new(AlphaNode[T])
  result.betaNode = new(MemoryNode[T])
  result.prodNodes = newTable[string, MemoryNode[T]]()
  result.idAttrNodes = newTable[IdAttr, HashSet[ptr AlphaNode[T]]]()
  new result.thenNodes
  result.thenNodes[] = initHashSet[ptr MemoryNode[T]]()

proc initProduction*[T, U](name: string, cb: SessionCallbackFn[T], query: QueryFn[T, U], filter: FilterFn[T]): Production[T, U] =
  result.name = name
  result.callback = cb
  result.query = query
  result.filter = filter

proc matches[I, T](vars: Vars[T], params: array[I, (string, T)]): bool =
  for (varName, val) in params:
    if vars[varname] != val:
      return false
  true

proc findIndex*[I, T](session: Session, prod: Production, params: array[I, (string, T)]): int =
  let vars = session.prodNodes[prod.name].vars
  result = vars.len - 1
  while result >= 0:
    if session.prodNodes[prod.name].enabledVars[result] and matches(vars[result], params):
      break
    result = result - 1

proc findIndex*(session: Session, prod: Production): int =
  let vars = session.prodNodes[prod.name].vars
  result = vars.len - 1
  while result >= 0:
    if session.prodNodes[prod.name].enabledVars[result]:
      break
    result = result - 1

proc findAllIndices*[I, T](session: Session, prod: Production, params: array[I, (string, T)]): seq[int] =
  let vars = session.prodNodes[prod.name].vars
  for i in 0 ..< vars.len:
    if session.prodNodes[prod.name].enabledVars[i] and matches(vars[i], params):
      result.add(i)

proc findAllIndices*(session: Session, prod: Production): seq[int] =
  let vars = session.prodNodes[prod.name].vars
  for i in 0 ..< vars.len:
    if session.prodNodes[prod.name].enabledVars[i]:
      result.add(i)

proc get*[T, U](session: Session[T], prod: Production[T, U], i: int): U =
  prod.query(session.prodNodes[prod.name].vars[i])
