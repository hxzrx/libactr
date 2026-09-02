# Vendored ACT-R snapshot — DO NOT EDIT

Frozen snapshot of the ASDF-packaged ACT-R port, vendored so that a fresh
clone of libactr alone can run the dev-time oracle suites (`libactr/oracle`,
`libactr/dual`) with no sibling `act-r/` checkout. The ASDF system name stays
`act-r` — libactr code resolves paths via `(asdf:system-relative-pathname
"act-r" ...)` and loads the system by name, so this tree is found through the
libactr source-registry entry's recursive scan.

Never edit files here. Refresh by re-vendoring from the source repo
(`git archive <sha> -- src tutorial act-r.asd`).

- Source repo:   https://gitee.com/hxz/act-r (git@gitee.com:hxz/act-r.git)
- Snapshot:      act-r @ da413e665c7657de1d88a868a92dfac9f60aaaef
- Upstream:      official ACT-R SVN r3493 (ACT-R 7.31.5); sync record in
                 `act-r/docs/upstream-sync.md` in the source repo
- Snapshot date: 2026-09-02
- Contents:      `src/` (173 files) + `tutorial/` (112 files) + `act-r.asd` —
                 exactly `git ls-files src tutorial act-r.asd` at the snapshot
                 commit. `test-models/`, `examples/`, `docs/` are intentionally
                 excluded (no libactr consumer references them).
- License:       LGPL-2.1 — see [COPYING.LESSER](COPYING.LESSER) in this
                 directory. This entire directory is LGPL-2.1; the libactr
                 repository root is MIT ([../../LICENSE](../../LICENSE)).

The engine writes a few files next to its sources when loaded
(`src/support/require-mode.lisp`, `src/support/extra-mode.lisp`, in-tree
`*.fasl` on some configurations). These are untracked build artifacts — see
`libactr/.gitignore`.
