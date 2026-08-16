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
  (make-instance 'past-tense-adapter
                 :model-package (find-package :mtt/past-tense-tutor)
                 :terminal-production '("RETRIEVE-IRREGULAR" "APPLY-REGULAR")))

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
verb, compares the student's answer against the lexicon/bug tables, and primes
retrieval with the matching fact so the matcher routes on-path /
off-path-buggy / off-path. See spec §5's 6-branch table."
  (flet ((gi (name) (mtt:adapter-intern a name)))
    (let* ((type (cdr (assoc "type" action :test #'string=)))
           (answer (string-upcase (cdr (assoc "value" action :test #'string=))))
           (verb-sym (mtt:adapter-goal-slot a session "VERB"))
           (verb (and verb-sym (symbol-name verb-sym)))
           ;; assoc-then-test guard: a MISSING analogy entry's cdr is nil,
           ;; itself a valid string designator reading "NIL", so feeding it
           ;; straight to string= would misroute a literal "nil" answer into
           ;; branch 5. Bind the table value once, compare only when bound.
           (analogy (and verb
                         (cdr (assoc verb (mtt/past-tense-tutor:analogy-bugs)
                                     :test #'string=)))))
      (unless (string= type "answer")
        (error "mtt/past-tense-adapter: unknown action type ~a" type))
      (multiple-value-bind (regular-p correct) (mtt/past-tense-tutor:verb-info verb)
        (let ((answer-sym (mtt:adapter-intern a answer)))
          (labels
              ((intent () `((,(gi "GOAL") ,(gi "PAST") ,answer-sym)))
               (bug (kind)
                 (mtt:adapter-primed-intent
                  a (intent)
                  (mtt:adapter-fact a "BUG-FACT" :kind kind
                                    :verb verb-sym :past answer-sym))))
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
              ;; 3 bug: over-regularize (verb+ED on an irregular verb)
              ((and (not regular-p) correct
                    (string= answer (concatenate 'string verb "ED")))
               (bug :over-regularize))
              ;; 4 bug: no-ed (unchanged regular verb)
              ((and regular-p (string= answer verb))
               (bug :no-ed))
              ;; 5 bug: vowel analogy (lookup table; ANALOGY is nil when the
              ;; verb has no entry — guarded above, see the let* comment)
              ((and analogy (string= answer analogy))
               (bug :vowel-analogy))
              ;; 6 unclassified (incl. unknown verbs): bare intent, no prime
              (t (mtt:make-step-intent :assignments (intent))))))))))
