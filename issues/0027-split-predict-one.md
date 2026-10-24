---
id: 27
title: Split predictOne into SLL and LL prediction
status: open
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

- [ ] Separate `execSll` (DFA walk, ATN on a miss) and `execLl` (with the
      parser call stack), sharing closure and reach
- [ ] A result type instead of `-2`; the loop exit as a named constant shared
      with codegen and the interpreter
- [ ] The loop-exit-on-no-viable-alternative recovery choice made explicitly
      in one place, with a test
- [ ] `expected` only computed when prediction fails
