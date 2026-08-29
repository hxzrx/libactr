;;;; src/past-tense-adapter.lisp — past-tense reference adapter (Phase 10, spec §5).
;;;; Implements the 3-method adapter protocol for the past-tense model. The
;;;; ADAPTER IS THE DOMAIN BRAIN: it looks up the verb class + correct form,
;;;; detects the bug pattern, and primes retrieval with the matching fact
;;;; (verb-fact with the discriminating class slot / bug-fact). Single-step:
;;;; one "answer" action per
;;;; problem; both correct productions are terminal (base list support, Task 2).
;;;; Stateless: all state lives on the session. NO global variables.
(defpackage :mtt/past-tense-adapter
  (:use :cl)
  (:nicknames :past-tense-adapter)
  (:export #:past-tense-adapter #:make-past-tense-adapter #:build-past-tense-model))
(in-package :mtt/past-tense-adapter)

(defclass past-tense-adapter (mtt:standard-domain-adapter) ()
  (:documentation "Reference past-tense domain adapter (English past-tense
inflection). Stateless. Subclasses standard-domain-adapter; step-done? is
INHERITED from the base (terminal list) — the third dogfood of the base."))

(defun make-past-tense-adapter ()
  "Construct the adapter. The phase-13 authoring gate (spec §6) runs HERE —
the named-predicate table lives in this adapter (not the tutor loader), so
construction IS validation: every past-tense bug-spec must pass
validate-bug-spec with the adapter's own predicates + env additions, else
error before the adapter is handed out."
  (let ((a (make-instance 'past-tense-adapter
                          :model-package (find-package :mtt/past-tense-tutor)
                          :terminal-production '("RETRIEVE-IRREGULAR" "APPLY-REGULAR"))))
    (%validate-specs! (mtt/past-tense-tutor:bug-specs))
    a))

;;; --- domain predicates (the named-predicate table for the bug-DSL) ---

(defun %verb+ed-p (answer verb)
  "Domain predicate: ANSWER is VERB with ED appended (both model-package
symbols here; compare on symbol-name)."
  (string= (symbol-name answer)
           (concatenate 'string (symbol-name verb) "ED")))

(defun %analogy-p (answer verb)
  "Domain predicate: ANSWER is the known vowel-analogy wrong form for VERB.
nil-guarded (phase-10 lesson #4): a verb with no table entry must NOT feed
nil to string= as the \"NIL\" designator."
  (let ((a (cdr (assoc (symbol-name verb)
                       (mtt/past-tense-tutor:analogy-bugs)
                       :test #'string=))))
    (and a (string= (symbol-name answer) a))))

(defun bug-predicates ()
  "The named-predicate table passed to detect-bug (zero global registry).
Keys match :when operators by symbol-name, so the adapter-package symbols
here pair with the tutor-package symbols in the specs."
  (list (cons 'verb+ed-p #'%verb+ed-p)
        (cons 'string= #'string=)
        (cons 'analogy-p #'%analogy-p)))

(defun %validate-specs! (specs)
  "Authoring-time gate (phase 13 spec §6): signal when any spec has errors,
return SPECS. Validated with the adapter's own named-predicate table
(bug-predicates — the same alist detect-bug receives at runtime) and the
adapter's env additions as :extra-env-names: VERB is the goal slot the specs'
:when forms read (also a fact-slot :from source), REGULAR-P / KNOWN-P are
derived by adapt-action (adapter-added, underivable from the spec)."
  (dolist (spec specs)
    (multiple-value-bind (errors warnings)
        (mtt:validate-bug-spec spec
                               :predicates (bug-predicates)
                               :extra-env-names '(verb regular-p known-p))
      (declare (ignore warnings))
      (when errors
        (error "invalid bug-spec ~a: ~{~a~^; ~}" (mtt:bug-spec-name spec) errors))))
  specs)

(defun build-past-tense-model ()
  "Read+compile the past-tense model + buggy library (reuses mtt/past-tense-tutor)."
  (mtt/past-tense-tutor:load-past-tense-model))

(defmethod mtt:prepare-session ((a past-tense-adapter) session problem-id)
  "PROBLEM-ID is the verb stem (e.g. \"go\"); intern it as a model-package symbol
in the goal's VERB slot (overriding the model's default initial-goal so one
compiled model serves any verb). Returns the session."
  (let ((verb (string-upcase (princ-to-string problem-id))))
    (mtt:adapter-set-goal a session "PAST-TENSE-TASK"
                          :verb (mtt:adapter-intern a verb)
                          :past nil)))

(defmethod mtt:adapt-action ((a past-tense-adapter) action session)
  "Translate a decoded student ACTION alist ((\"type\" . \"answer\")
  (\"value\" . \"went\")) into a primed step-intent. The adapter classifies the
  verb, compares the student's answer against the lexicon, and routes: correct
  -> verb-fact priming; else the phase-12 bug-DSL (detect-bug over
  bug-specs with the domain predicate table; env carries the goal slots plus
  the derived regular-p / known-p); no match -> bare intent (off-path,
  incl. unknown verbs — design behavior)."
  (flet ((gi (name) (mtt:adapter-intern a name)))
    (let* ((type (cdr (assoc "type" action :test #'string=)))
           (answer (string-upcase (cdr (assoc "value" action :test #'string=))))
           (verb-sym (mtt:adapter-goal-slot a session "VERB"))
           (verb (and verb-sym (symbol-name verb-sym))))
      (unless (string= type "answer")
        (mtt:signal-bad-request "mtt/past-tense-adapter: unknown action type ~a" type))
      (multiple-value-bind (regular-p correct) (mtt/past-tense-tutor:verb-info verb)
        (let ((answer-sym (mtt:adapter-intern a answer)))
          (labels ((intent () `((,(gi "GOAL") ,(gi "PAST") ,answer-sym))))
            (cond
              ;; 1-2 correct: verb-fact whose class slot literal routes the
              ;; production (regular -> apply-regular, irregular ->
              ;; retrieve-irregular); spec §3 amended (isa is not tested by
              ;; act-r in buffer conditions, class IS in both engines).
              ((and correct (string= answer correct))
               (mtt:adapter-primed-intent
                a (intent)
                (mtt:adapter-fact a "VERB-FACT"
                                  :verb verb-sym
                                  :class (gi (if regular-p "REGULAR" "IRREGULAR"))
                                  :past answer-sym)))
              ;; 3-5 bugs via the DSL; 6 unclassified (incl. unknown verbs)
              (t
               (let* ((answers (list answer-sym))
                      (env (append (list (cons (gi "REGULAR-P") regular-p)
                                         (cons (gi "KNOWN-P") (and correct t)))
                                   (mtt:bug-goal-env a session)))
                      (spec (mtt:detect-bug (mtt/past-tense-tutor:bug-specs)
                                            answers env
                                            :predicates (bug-predicates))))
                 (if spec
                     (mtt:bug-intent a session spec answers)
                     (mtt:make-step-intent :assignments (intent))))))))))))
