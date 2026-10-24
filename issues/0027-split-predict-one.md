---
id: 27
title: Split predictOne into SLL and LL prediction
status: done
labels: [parser, cleanup]
depends: [24, 25, 26]
---

`predictOne` in `runtime/parser.nim` is one ~150-line proc for both modes,
switched by `fullContext`:

- three cache variables: `cache`, `sllCache` (a fresh cache when none is
  given) and `activeCache`;
- the "accepted at EOF" block twice;
- magic results: `-2` for "retry in full LL", `high(int)` for a precedence
  loop exit;
- when nothing is viable, it returns the loop exit of any decision that has
  one, before the LL retry, as a recovery shortcut;
- `expected` computed on every step, used only on failure.

Do this after 24 to 26, which rewrite most of it.

## Tasks

- [x] Separate `execSll` (DFA walk, ATN on a miss) and `execLl` (with the
      parser call stack), sharing closure and reach
- [x] A result type instead of `-2`; the loop exit as a named constant shared
      with codegen and the interpreter
- [x] The loop-exit-on-no-viable-alternative recovery choice made explicitly
      in one place, with a test
- [x] `expected` only computed when prediction fails

## Outcome

Issues 24 to 26 already split it: `predictSll` walks the DFA and extends
it over the ATN, `predictLl` predicts with the parser call stack, and both
use `atnClosure`, `advance` and `ending`; `expectedAtn` runs only when full
context fails. What was left:

- `predictSll` returns an `Option[int]`, none for a full-context retry, as
  does a resolved DFA state; `-2` is gone.
- `loopExit` names `high(int)` in the runtime, the analysis, the
  interpreter and generated parsers (`of loopExit: break`).
- `noViable` makes the recovery choice, for SLL and full context:
  `parsegen_no_viable_operator_ends_the_loop` checks that the caller
  reports `expected ';'`, not `expected ';' or '+'` from inside the loop.
- `predict` needs a cache, which every caller passes, so the fresh caches
  made for a nil one are gone.
