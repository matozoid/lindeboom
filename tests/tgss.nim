# The prediction call stacks are private to the runtime, so this suite
# includes it.
include lindeboom/runtime/parser

proc frame(gss: Gss, returnState, below: int): int =
  gss.single(gss.push(returnState, below, 0))

block gss_equal_stack_sets_share_an_id:
  # {5·1, 5·2} merged frame by frame is the stack 5 over {1, 2}.
  let gss = Gss()
  let one = gss.frame(1, gss.bottom)
  let two = gss.frame(2, gss.bottom)
  doAssert gss.union(gss.frame(5, one), gss.frame(5, two)) ==
    gss.frame(5, gss.union(one, two))

block gss_union_is_associative_and_commutative:
  let gss = Gss()
  let a = gss.frame(5, gss.frame(1, gss.bottom))
  let b = gss.frame(5, gss.frame(2, gss.bottom))
  let c = gss.union(gss.frame(6, gss.bottom), gss.bottom)
  doAssert gss.union(gss.union(a, b), c) == gss.union(a, gss.union(b, c))
  doAssert gss.union(gss.union(a, c), b) == gss.union(gss.union(c, b), a)

block gss_precedence_keeps_frames_apart:
  # The same return state with another caller precedence is another frame.
  let gss = Gss()
  let low = gss.single(gss.push(5, gss.bottom, 0))
  let high = gss.single(gss.push(5, gss.bottom, 3))
  doAssert gss.sets[gss.union(low, high) - 1].len == 2
