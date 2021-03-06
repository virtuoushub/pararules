import unittest
import pararules
from pararules/engine import getParent
import tables

type
  Id* = enum
    Alice, Bob, Charlie, David, George,
    Seth, Thomas, Xavier, Yair, Zach
  Attr* = enum
    Color, LeftOf, RightOf, Height, On, Self

schema Fact(Id, Attr):
  Color: string
  LeftOf: Id
  RightOf: Id
  Height: int
  On: string
  Self: Id

proc `==`(a: int, b: Id): bool =
  a == b.ord

test "number of conditions != number of facts":
  var session = initSession(Fact)
  session.add:
    rule numCondsAndFacts(Fact):
      what:
        (b, Color, "blue")
        (y, LeftOf, z)
        (a, Color, "maize")
        (y, RightOf, b)
        (x, Height, h)
      then:
        check a == Alice
        check b == Bob
        check y == Yair
        check z == Zach

  let prodNode = session.prodNodes["numCondsAndFacts"]

  session.insert(Bob, Color, "blue")
  session.insert(Yair, LeftOf, Zach)
  session.insert(Alice, Color, "maize")
  session.insert(Yair, RightOf, Bob)

  session.insert(Xavier, Height, 72)
  session.insert(Thomas, Height, 72)
  session.insert(George, Height, 72)

  check prodNode.debugFacts.len == 3
  check prodNode.debugFacts[0].len == 5

test "adding facts out of order":
  var session = initSession(Fact)
  session.add:
    rule outOfOrder(Fact):
      what:
        (x, RightOf, y)
        (y, LeftOf, z)
        (z, Color, "red")
        (a, Color, "maize")
        (b, Color, "blue")
        (c, Color, "green")
        (d, Color, "white")
        (s, On, "table")
        (y, RightOf, b)
        (a, LeftOf, d)
      then:
        check a == Alice
        check b == Bob
        check y == Yair
        check z == Zach

  let prodNode = session.prodNodes["outOfOrder"]

  session.insert(Xavier, RightOf, Yair)
  session.insert(Yair, LeftOf, Zach)
  session.insert(Zach, Color, "red")
  session.insert(Alice, Color, "maize")
  session.insert(Bob, Color, "blue")
  session.insert(Charlie, Color, "green")
 
  session.insert(Seth, On, "table")
  session.insert(Yair, RightOf, Bob)
  session.insert(Alice, LeftOf, David)

  session.insert(David, Color, "white")

  check prodNode.debugFacts.len == 1
  check prodNode.debugFacts[0].len == 10

test "duplicate facts":
  var session = initSession(Fact)
  let rule1 =
    rule duplicateFacts(Fact):
      what:
        (x, Self, y)
        (x, Color, c)
        (y, Color, c)
  session.add(rule1)

  let prodNode = session.prodNodes["duplicateFacts"]

  session.insert(Bob, Self, Bob)
  session.insert(Bob, Color, "red")

  check prodNode.debugFacts.len == 1
  check prodNode.debugFacts[0].len == 3
  check session.query(rule1).c == "red"

  # update *both* duplicate facts from red to green
  session.insert(Bob, Color, "green")

  check prodNode.debugFacts.len == 1
  check prodNode.debugFacts[0].len == 3
  check session.query(rule1).c == "green"

test "removing facts":
  var session = initSession(Fact)
  session.add:
    rule removingFacts(Fact):
      what:
        (b, Color, "blue")
        (y, LeftOf, z)
        (a, Color, "maize")
        (y, RightOf, b)

  let prodNode = session.prodNodes["removingFacts"]

  session.insert(Bob, Color, "blue")
  session.insert(Yair, LeftOf, Zach)
  session.insert(Alice, Color, "maize")
  session.insert(Yair, RightOf, Bob)
  check prodNode.debugFacts.len == 1

  session.retract(Yair, RightOf, Bob)
  check prodNode.debugFacts.len == 0
  check prodNode.getParent.debugFacts.len == 1
  check prodNode.getParent.debugFacts[0].len == 3

  session.retract(Bob, Color, "blue")
  check prodNode.debugFacts.len == 0
  check prodNode.getParent.debugFacts.len == 0

  # re-insert to make sure idAttrNodes was cleared correctly
  session.insert(Bob, Color, "blue")
  session.insert(Yair, RightOf, Bob)
  check prodNode.debugFacts.len == 1
  check prodNode.getParent.debugFacts.len == 1
  check prodNode.getParent.debugFacts[0].len == 3

test "updating facts":
  var session = initSession(Fact)
  var zVal: int
  session.add:
    rule updatingFacts(Fact):
      what:
        (b, Color, "blue")
        (y, LeftOf, z)
        (a, Color, "maize")
        (y, RightOf, b)
      then:
        zVal = z

  let prodNode = session.prodNodes["updatingFacts"]

  session.insert(Bob, Color, "blue")
  session.insert(Yair, LeftOf, Zach)
  session.insert(Alice, Color, "maize")
  session.insert(Yair, RightOf, Bob)
  check prodNode.debugFacts.len == 1
  check zVal == Zach

  session.insert(Yair, LeftOf, Xavier)
  check prodNode.debugFacts.len == 1
  check zVal == Xavier

test "updating facts in different alpha nodes":
  var session = initSession(Fact)
  session.add:
    rule updatingFactsDiffNodes(Fact):
      what:
        (b, Color, "blue")
        (y, LeftOf, Zach)
        (a, Color, "maize")
        (y, RightOf, b)

  let prodNode = session.prodNodes["updatingFactsDiffNodes"]

  session.insert(Bob, Color, "blue")
  session.insert(Yair, LeftOf, Zach)
  session.insert(Alice, Color, "maize")
  session.insert(Yair, RightOf, Bob)
  check prodNode.debugFacts.len == 1

  session.insert(Yair, LeftOf, Xavier)
  check prodNode.debugFacts.len == 0

test "facts can be stored in multiple alpha nodes":
  var session = initSession(Fact)
  var alice, zach: int
  session.add:
    rule rule1(Fact):
      what:
        (a, LeftOf, Zach)
      then:
        alice = a
  session.add:
    rule rule2(Fact):
      what:
        (a, LeftOf, z)
      then:
        zach = z
  session.insert(Alice, LeftOf, Zach)
  check alice == Alice
  check zach == Zach

test "complex conditions":
  var session = initSession(Fact)
  let rule1 =
    rule complexCond(Fact):
      what:
        (b, Color, "blue")
        (y, LeftOf, z)
        (a, Color, "maize")
        (y, RightOf, b)
      cond:
        z != Zach
  session.add(rule1)

  session.insert(Bob, Color, "blue")
  session.insert(Yair, LeftOf, Zach)
  session.insert(Alice, Color, "maize")
  session.insert(Yair, RightOf, Bob)
  check session.findAll(rule1).len == 0

  session.insert(Yair, LeftOf, Charlie)
  check session.findAll(rule1).len == 1

test "out-of-order joins between id and value":
  var session = initSession(Fact)
  let rule1 =
    rule rule1(Fact):
      what:
        (b, RightOf, Alice)
        (y, RightOf, b)
        (b, Color, "blue")
  session.add(rule1)

  session.insert(Bob, RightOf, Alice)
  session.insert(Bob, Color, "blue")
  session.insert(Yair, RightOf, Bob)
  check session.findAll(rule1).len == 1

# this was failing because we weren't testing conditions
# in join nodes who are children of the root memory node
test "simple conditions":
  var count = 0

  var session = initSession(Fact)
  session.add:
    rule simpleCond(Fact):
      what:
        (b, Color, "blue")
      cond:
        false
      then:
        count += 1

  session.insert(Bob, Color, "blue")

  check count == 0

test "queries":
  let getPerson =
    rule getPerson(Fact):
      what:
        (id, Color, color)
        (id, LeftOf, leftOf)
        (id, Height, height)

  var session = initSession(Fact)
  session.add(getPerson)

  session.insert(Bob, Color, "blue")
  session.insert(Bob, LeftOf, Zach)
  session.insert(Bob, Height, 72)

  session.insert(Alice, Color, "green")
  session.insert(Alice, LeftOf, Bob)
  session.insert(Alice, Height, 64)

  session.insert(Charlie, Color, "red")
  session.insert(Charlie, LeftOf, Alice)
  session.insert(Charlie, Height, 72)

  let loc = session.find(getPerson, id = Bob)
  check loc >= 0
  let res = session.get(getPerson, loc)
  check res.id == Bob
  check res.color == "blue"
  check res.leftOf == Zach
  check res.height == 72

  let resQuery = session.query(getPerson, id = Bob)
  check resQuery == res

  let locs = session.findAll(getPerson, height = 72)
  check locs.len == 2
  let res1 = session.get(getPerson, locs[0])
  let res2 = session.get(getPerson, locs[1])
  check res1.id == Bob
  check res2.id == Charlie

test "creating a ruleset":
  let rules =
    ruleset:
      rule bob(Fact):
        what:
          (b, Color, "blue")
          (b, RightOf, a)
        then:
          check a == Alice
          check b == Bob
      rule alice(Fact):
        what:
          (a, Color, "red")
          (a, LeftOf, b)
        then:
          check a == Alice
          check b == Bob

  var session = initSession(Fact)
  for r in rules.fields:
    session.add(r)

  let bobNode = session.prodNodes["bob"]
  let aliceNode = session.prodNodes["alice"]

  session.insert(Bob, Color, "blue")
  session.insert(Bob, RightOf, Alice)
  session.insert(Alice, Color, "red")
  session.insert(Alice, LeftOf, Bob)

  check bobNode.debugFacts.len == 1
  check aliceNode.debugFacts.len == 1

test "don't trigger rule when updating certain facts":
  var count = 0

  var session = initSession(Fact)
  session.add:
    rule dontTrigger(Fact):
      what:
        (b, Color, "blue")
        (a, Color, c, then = false)
      then:
        count += 1

  session.insert(Bob, Color, "blue")
  session.insert(Alice, Color, "red")
  session.insert(Alice, Color, "maize")

  check count == 1

test "inserting inside a rule is delayed":
  let rules =
    ruleset:
      rule firstRule(Fact):
        what:
          (b, Color, "blue")
          (a, Color, c, then = false)
        then:
          # if this insertion is not delayed, it will throw an error
          session.insert(Alice, Color, "maize")
      rule secondRule(Fact):
        what:
          (b, Color, "blue")
          (a, Color, c, then = false)

  var session = initSession(Fact)
  for r in rules.fields:
    session.add(r)

  session.insert(Bob, Color, "blue")
  session.insert(Alice, Color, "red")

test "inserting inside a rule can trigger rule more than once":
  var count = 0
  let rules =
    ruleset:
      rule firstRule(Fact):
        what:
          (b, Color, "blue")
        then:
          session.insert(Alice, Color, "maize")
          session.insert(Charlie, Color, "gold")
      rule secondRule(Fact):
        what:
          (Alice, Color, c1)
          (otherPerson, Color, c2)
        cond:
          otherPerson != Alice.ord
        then:
          count += 1

  var session = initSession(Fact)
  for r in rules.fields:
    session.add(r)

  session.insert(Alice, Color, "red")
  session.insert(Bob, Color, "blue")

  check count == 3

test "inserting inside a rule cascades":
  let rules =
    ruleset:
      rule firstRule(Fact):
        what:
          (b, Color, "blue")
        then:
          session.insert(Charlie, RightOf, Bob)
      rule secondRule(Fact):
        what:
          (c, RightOf, b)
        then:
          session.insert(b, LeftOf, c)
      rule thirdRule(Fact):
        what:
          (b, LeftOf, c)

  var session = initSession(Fact)
  for r in rules.fields:
    session.add(r)

  session.insert(Bob, Color, "blue")

  let first = session.prodNodes["firstRule"]
  let second = session.prodNodes["secondRule"]
  let third = session.prodNodes["thirdRule"]

  check first.debugFacts.len == 1
  check second.debugFacts.len == 1
  check third.debugFacts.len == 1

test "conditions can use external values":
  var session = initSession(Fact)
  var allowRuleToFire = false
  let rule1 =
    rule rule1(Fact):
      what:
        (a, LeftOf, b)
      cond:
        allowRuleToFire
  session.add(rule1)

  session.insert(Alice, LeftOf, Zach)
  allowRuleToFire = true
  # this was causing an assertion error because
  # previously i assumed that all deletions
  # in leftActivation would succeed.
  session.insert(Alice, LeftOf, Bob)

  check session.findAll(rule1).len == 1

  # now we prevent the rule from firing again,
  # but the old "Alice, LeftOf, Bob" fact
  # is still retractd successfully

  allowRuleToFire = false
  session.insert(Alice, LeftOf, Zach)

  check session.findAll(rule1).len == 0

test "id + attr combos can be stored in multiple alpha nodes":
  let rules =
    ruleset:
      rule getAlice(Fact):
        what:
          (Alice, Color, color)
          (Alice, Height, height)
      rule getPerson(Fact):
        what:
          (id, Color, color)
          (id, Height, height)

  var session = initSession(Fact)
  for r in rules.fields:
    session.add(r)

  session.insert(Alice, Color, "blue")
  session.insert(Alice, Height, 60)

  let alice = session.query(rules.getAlice)
  check alice.color == "blue"
  check alice.height == 60

  session.retract(Alice, Color, "blue")

  let index = session.find(rules.getAlice)
  check index == -1

test "IDs can be arbitrary integers":
  let zach = Id.high.ord + 1
  var session = initSession(Fact)
  session.add:
    rule rule1(Fact):
      what:
        (b, Color, "blue")
        (y, LeftOf, z)
        (a, Color, "maize")
        (y, RightOf, b)
        (z, LeftOf, b)
      then:
        check a == Alice
        check b == Bob
        check y == Yair
        check z == zach

  let prodNode = session.prodNodes["rule1"]

  session.insert(Bob, Color, "blue")
  session.insert(Yair, LeftOf, zach)
  session.insert(Alice, Color, "maize")
  session.insert(Yair, RightOf, Bob)
  session.insert(zach, LeftOf, Bob)

  check prodNode.debugFacts.len == 1
  check prodNode.debugFacts[0].len == 5

test "don't use the fast update mechanism if it's part of a join":
  let rules =
    ruleset:
      rule rule1(Fact):
        what:
          (Bob, LeftOf, id)
          (id, Color, color)
          (id, Height, height)

  var session = initSession(Fact)
  for r in rules.fields:
    session.add(r)

  session.insert(Alice, Color, "blue")
  session.insert(Alice, Height, 60)
  session.insert(Charlie, Color, "green")
  session.insert(Charlie, Height, 72)

  session.insert(Bob, LeftOf, Alice)
  check session.query(rules.rule1).id == Alice

  session.insert(Bob, LeftOf, Charlie)
  check session.query(rules.rule1).id == Charlie

  let prodNode = session.prodNodes["rule1"]
  check prodNode.debugFacts.len == 1

# this one is not used...
# it's just here to make sure we can define
# multiple schemas in one module
schema Stuff(Id, Attr):
  Color: int
  LeftOf: Id
  RightOf: Id
  Height: float
  On: string
  Self: Id
