# mtt — Model-Tracing Tutor Engine

`mtt` is an independent, multi-user-safe model-tracing production engine written
in Common Lisp. It parses, compiles, and matches ACT-R-style declarative
chunks and procedural productions **without** running the full ACT-R
interpreter — enabling high-throughput, side-effect-free model tracing for
cognitive-tutor workloads.

This project is a **sibling** of `act-r/` (the ASDF-managed ACT-R library).
`act-r/` is used **only** as a dev-time oracle for dual-track regression
testing (see `mtt/dual`); the core engine has **no** runtime dependency on
ACT-R.

## Systems

The `mtt.asd` system file defines four ASDF systems:

| System        | Purpose                                          | Depends on        |
|---------------|--------------------------------------------------|-------------------|
| `mtt`         | Core engine (types, reader, compiler, matcher)   | —                 |
| `mtt/test`    | Fast FiveAM unit tests (no ACT-R)                | `mtt`, `fiveam`   |
| `mtt/oracle`  | act-r dual-track oracle adapter (**dev-time**)   | `mtt`, `act-r`    |
| `mtt/dual`    | Dual-track regression vs act-r oracle            | `mtt/test`, `mtt/oracle` |

## Prerequisites

- SBCL 2.6.7 (any modern ANSI CL with ASDF 3.3+ should work).
- [FiveAM](https://github.com/sionescu/fiveam) for the test suite — available
  via Quicklisp: `(ql:quickload :fiveam)`.
- `act-r/` registered with ASDF (only needed for `mtt/oracle` and `mtt/dual`).

## Loading

```lisp
;; core engine
(asdf:load-system "mtt")
;; or, if registered via Quicklisp:
(ql:quickload :mtt)

(in-package :mtt)
```

## Running the tests

### Fast unit tests (no ACT-R dependency)

```lisp
(ql:quickload :mtt/test)
(5am:run! :mtt)
```

From the shell:

```bash
sbcl --non-interactive \
  --eval '(ql:quickload :mtt/test)' \
  --eval '(5am:run! :mtt)' \
  --eval '(sb-ext:quit)'
```

### Dual-track regression (needs act-r via the oracle)

```lisp
(ql:quickload :mtt/dual)
(5am:run! :mtt)
```

From the shell:

```bash
sbcl --non-interactive \
  --eval '(ql:quickload :mtt/dual)' \
  --eval '(5am:run! :mtt)' \
  --eval '(sb-ext:quit)'
```

## Architecture constraints

- **Zero global state.** The core engine holds **no** mutable global/special
  variables. All model state (chunk-types, chunks, productions, buffer state)
  is carried in explicitly-passed data structures, so a single Lisp image can
  trace many independent models/users concurrently without interference. This
  is the central design hard-constraint of the engine.
- **No runtime ACT-R dependency.** `act-r/` is referenced exclusively by the
  `mtt/oracle` system for dual-track regression testing during development.
  Production deployments load only `mtt`.
- **Single-threaded by design.** Concurrency is achieved by re-entrancy and
  state isolation, not threads.

## Project layout

```
mtt/
├── mtt.asd            # ASDF system definitions (mtt, mtt/test, mtt/oracle, mtt/dual)
├── README.md
├── src/
│   ├── package.lisp   # :mtt package definition + exports
│   ├── types.lisp     # data model (chunks, chunk-types, model-definition)
│   ├── reader.lisp    # model file reader/parser
│   ├── compiler.lisp  # typed slot-tests + chunk-type inheritance
│   ├── matcher.lisp   # production matching / unification
│   └── oracle.lisp    # act-r dual-track oracle adapter (dev-time only)
└── tests/
    ├── suite.lisp             # FiveAM master suite + run-all entry point
    ├── test-types.lisp
    ├── test-reader.lisp
    ├── test-compiler.lisp
    ├── test-matcher.lisp
    └── test-dual-track.lisp
```

## Status

Kernel complete (Tasks 1-7): types, reader, compiler, matcher, oracle, and the
dual-track regression suite. **146/146 checks pass** (138 unit + 6 oracle + 2
dual-track) under SBCL 2.6.7 against act-r SVN r3493.

### Dual-track regression results

The `mtt/dual` suite cross-checks mtt's `model-matching-productions` against
the act-r oracle (`oracle-matches-p`) on every tutorial model.  Both engines
start from the **same goal-only state** (goal = model's `initial-goal`, all
other buffers empty); a discrepancy indicates either an mtt matcher bug or an
out-of-subset feature.

**Models covered** (tutorial/unit1 + unit2):

| Model                      | Productions | Result                                |
|----------------------------|-------------|---------------------------------------|
| addition.lisp              | 4           | AGREE (0 discrepancies)               |
| count.lisp                 | 3           | AGREE                                 |
| semantic.lisp              | 4           | AGREE                                 |
| tutor-model-solution.lisp  | 6           | AGREE                                 |
| demo2-model.lisp           | 4           | AGREE                                 |
| tutor-model.lisp           | 0           | SKIP (no productions; has goal)       |
| unit2-assignment-model.lisp| 0           | SKIP (no productions; has goal)       |
| broken-addition.lisp       | —           | KNOWN NON-DEFECT (file is deliberately malformed: unbalanced parens → reader EOF error, caught by handler-case) |

**Summary: 5 models with productions, all AGREE (0 discrepancies); 2 models
skipped (no productions); 1 known non-defect (deliberately broken file).**

### Bug fix during Task 7

The dual-track work exposed a deferred `:?` buffer-state-query inversion
(noted in Task 5): `?buf> buffer empty` matched when the buffer was
**occupied** and failed when **empty** — exactly backwards.  Fixed in
`src/matcher.lisp`: `?buf>` queries now evaluate state keywords (`buffer`
empty/full/failure, `state` free/busy/error) against buffer occupancy/module
state, handled **before** the null-chunk check so `buffer empty` can match.
Locked in by 9 new unit tests in `test-matcher.lisp`.
