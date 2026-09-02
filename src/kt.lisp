;;;; src/kt.lisp — knowledge tracing (Corbett & Anderson 4-parameter BKT, Phase 6)
;;;; Pure Bayesian Knowledge Tracing over a per-KC correct/incorrect sequence.
;;;; Mastery is a DETERMINISTIC DERIVATION of the event log — never persisted;
;;;; recomputed by folding this module over a student's kc-event stream. NO global
;;;; mutable state: the four parameter defaults are defstruct slot initforms
;;;; (lambda-literal values), not defvar. Formulas verified against Wikipedia BKT
;;;; (equations a–d) / IEDMS Standard-BKT / Corbett & Anderson (1995). See
;;;; docs/2026-08-11-libactr-phase6-knowledge-tracing-design.md §3.
(in-package :libactr)

(defstruct kt-params
  "Four BKT parameters. Defaults L0=0.1, transit=0.1, guess=0.2, slip=0.1
(G+S=0.3<1, the non-deceptive-region invariant). defstruct auto-generates
make-kt-params (&key l0 transit guess slip overrides) with these initforms as
defaults — NO separate defun, NO defvar. OVERRIDES (Phase 7): an alist
(kc . kt-params) giving per-KC parameter sets; kt-params-for falls back to
these base params when a kc has no override. Nesting is not supported."
  (l0      0.1d0 :type double-float)   ; prior P(known) before any observation
  (transit 0.1d0 :type double-float)   ; P(learn) per opportunity
  (guess   0.2d0 :type double-float)   ; P(correct | not known)
  (slip   0.1d0 :type double-float)    ; P(incorrect | known)
  (overrides nil))                     ; alist (kc . kt-params); per-KC, fallback=self

(defun kt-params-for (kc params)
  "Return the kt-params to fold for KC: its override in PARAMS if present, else
PARAMS itself (the base defaults). OVERRIDES is an alist (kc . kt-params); kc
keys are compared by eql (assoc default) — use keyword or symbol kc ids. No
nesting: overrides live only on the top-level PARAMS."
  (or (cdr (assoc kc (kt-params-overrides params))) params))

(defun kt-update (p-l correct-p params)
  "One BKT step. Equation (b) [correct] or (c) [incorrect] gives the posterior
P(L|obs) via Bayes; equation (d) applies transit (learning may occur on this
opportunity). Returns the new P(L) (post-transit). PARAMS supplies G, S, T.
Caller invariant G+S<1 keeps the denominator positive."
  (let* ((g (kt-params-guess params))
         (s (kt-params-slip params))
         (tr (kt-params-transit params))
         (posterior
           (if correct-p
               ;; (b) P(L|correct) = P(L)(1-S) / (P(L)(1-S) + (1-P(L))G)
               (/ (* p-l (- 1.0d0 s))
                  (+ (* p-l (- 1.0d0 s)) (* (- 1.0d0 p-l) g)))
               ;; (c) P(L|incorrect) = P(L)S / (P(L)S + (1-P(L))(1-G))
               (/ (* p-l s)
                  (+ (* p-l s) (* (- 1.0d0 p-l) (- 1.0d0 g)))))))
    ;; (d) P(L) <- posterior + (1-posterior)*T
    (+ posterior (* (- 1.0d0 posterior) tr))))

(defun kt-posterior (observations params)
  "Fold kt-update over OBSERVATIONS (a list of booleans, chronological order)
starting from P(L) = L0. Empty list -> L0. Returns the post-transit mastery P(L)
after the last observation (equation (d) value: the student's current knowledge
probability — the canonical mastery report point)."
  (let ((l0 (kt-params-l0 params)))
    (if (null observations)
        l0
        (reduce (lambda (pl obs) (kt-update pl obs params))
                observations
                :initial-value l0))))
