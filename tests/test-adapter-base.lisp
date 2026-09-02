;;;; tests/test-adapter-base.lisp — standard-domain-adapter plumbing helpers (Phase 8).
;;;; Suite :libactr/server (defined in tests/test-server.lisp). Pure helper tests: a
;;;; minimal test-only subclass + synthetic sessions; no real model/HTTP.
(in-package :libactr/server-test)
(in-suite :libactr/server)

(defclass test-adapter (standard-domain-adapter) ())

(defun make-test-adapter (&optional (terminal "DONE"))
  (make-instance 'test-adapter
                 :model-package (find-package :libactr/server-test)
                 :terminal-production terminal))

(defun %fake-session (state)
  "Minimal cognitive-session carrying STATE (a buffer-state)."
  (make-instance 'cognitive-session
                 :model (make-model-definition)
                 :state state
                 :event-log (make-event-log)
                 :student-id 's :problem-id 'p))

(test adapter-intern.interns-in-model-package
  (let ((a (make-test-adapter)))
    (is (eq (adapter-intern a "FOO") (intern "FOO" :libactr/server-test)))))

(test adapter-fact.builds-interned-chunk-values-pass-through
  (let* ((a (make-test-adapter))
         (c (adapter-fact a "T1" :n1 1 :n2 2)))
    (is (eq (chunk-isa c) (intern "T1" :libactr/server-test)))
    (is (eql 1 (cdr (assoc (intern "N1" :libactr/server-test) (chunk-slots c)))))
    (is (eql 2 (cdr (assoc (intern "N2" :libactr/server-test) (chunk-slots c)))))))

(test adapter-set-goal-and-goal-slot.roundtrip
  (let* ((a (make-test-adapter))
         (s (%fake-session (make-buffer-state))))
    (adapter-set-goal a s "G" :arg1 7 :arg2 8)
    (is (eql 7 (adapter-goal-slot a s "ARG1")))
    (is (eql 8 (adapter-goal-slot a s "ARG2")))
    (is (null (adapter-goal-slot a s "MISSING")))))

(test adapter-goal-slot.nil-when-no-goal-buffer
  (let ((s (%fake-session (make-buffer-state))))   ; empty state, no goal chunk
    (is (null (adapter-goal-slot (make-test-adapter) s "ARG1")))))

(test adapter-primed-intent.shape
  (let* ((a (make-test-adapter))
         (fact (adapter-fact a "T" :x 1))
         (intent (adapter-primed-intent a '((goal foo 1)) fact)))
    (is (equal '((goal foo 1)) (step-intent-assignments intent)))
    (let ((prime (step-intent-prime intent)))
      (is (consp prime))
      (is (eq (car (first prime)) (intern "RETRIEVAL" :libactr/server-test)))
      (is (eq (cdr (first prime)) fact)))))

(test step-done.default-on-path-matching-terminal
  (let* ((a (make-test-adapter "DONE"))
         (tr (make-trace-result :status :on-path
               :production (make-production 'done nil nil nil :correct nil))))
    (is (step-done? a tr (%fake-session (make-buffer-state))))))

(test step-done.default-fails-when-production-name-mismatches
  (let* ((a (make-test-adapter "DONE"))
         (tr (make-trace-result :status :on-path
               :production (make-production 'other nil nil nil :correct nil))))
    (is (null (step-done? a tr (%fake-session (make-buffer-state)))))))

(test step-done.default-fails-when-off-path
  (let* ((a (make-test-adapter "DONE"))
         (tr (make-trace-result :status :off-path
               :production (make-production 'done nil nil nil :correct nil))))
    (is (null (step-done? a tr (%fake-session (make-buffer-state)))))))

(test adapter-terminal-production.string-normalized-to-list
  "Phase 10: a bare-string terminal-production is normalized to a one-element
list; a list passes through unchanged."
  (is (equal '("DONE") (adapter-terminal-production (make-test-adapter))))
  (is (equal '("RETRIEVE-IRREGULAR" "APPLY-REGULAR")
             (adapter-terminal-production (make-test-adapter
                                           '("RETRIEVE-IRREGULAR" "APPLY-REGULAR"))))))

(test step-done.default-matches-any-terminal-in-list
  "Phase 10: with a multi-name terminal list, the default step-done? accepts an
on-path production matching ANY listed name, and still rejects others."
  (let* ((a (make-test-adapter '("RETRIEVE-IRREGULAR" "APPLY-REGULAR")))
         (mk (lambda (name)
               (make-trace-result :status :on-path
                 :production (make-production name nil nil nil :correct nil))))
         (s (%fake-session (make-buffer-state))))
    (is (step-done? a (funcall mk 'retrieve-irregular) s))
    (is (step-done? a (funcall mk 'apply-regular) s))
    (is (null (step-done? a (funcall mk 'some-other) s)))))

;;; --- Phase 12: bug-DSL runtime helpers + malformed-input condition ----------

(test signal-bad-request.signals-condition-with-message
  (let ((err (nth-value 1 (ignore-errors (signal-bad-request "bad ~a!" "id")))))
    (is (typep err 'bad-tutor-request))
    (is (string= "bad id!" (bad-tutor-request-message err)))))

(test bug-goal-env.is-goal-chunk-slots
  (let* ((a (make-test-adapter))
         (s (%fake-session (make-buffer-state))))
    (is (null (bug-goal-env a s)))            ; empty goal -> nil
    (adapter-set-goal a s "G" :x 1 :y 2)
    (is (equal (list (cons (intern "X" :libactr/server-test) 1)
                     (cons (intern "Y" :libactr/server-test) 2))
               (bug-goal-env a s)))))

(test bug-intent.shape
  "bug-intent writes each answer to its goal slot and primes a bug-fact with
the kind keyword + fact slots filled from answers, goal slots, and literals."
  (let* ((a (make-test-adapter))
         (s (%fake-session (make-buffer-state))))
    (adapter-set-goal a s "TASK" :verb (intern "GO" :libactr/server-test))
    (let* ((spec (make-bug-spec
                  :name (intern "BUGGY-X" :libactr/server-test)
                  :kind :over :kc :irr :feedback "f"
                  :goal-type (intern "TASK" :libactr/server-test)
                  :answers (list (list :action "value"
                                   :slot (intern "PAST" :libactr/server-test)))
                  :fact-slots (list (list (intern "VERB" :libactr/server-test)
                                          :from (list :goal
                                                      (intern "VERB" :libactr/server-test)))
                                    (list (intern "PAST" :libactr/server-test)
                                          :from (list :answer 0))
                                    (list (intern "JUNK" :libactr/server-test) :literal 0))
                  :when '(t)))
           (intent (bug-intent a s spec (list (intern "WENT" :libactr/server-test)))))
      (is (equal (list (list (intern "GOAL" :libactr/server-test)
                             (intern "PAST" :libactr/server-test)
                             (intern "WENT" :libactr/server-test)))
                 (step-intent-assignments intent)))
      (let* ((prime (cdr (first (step-intent-prime intent))))
             (slots (chunk-slots prime)))
        (is (eq (intern "BUG-FACT" :libactr/server-test) (chunk-isa prime)))
        (is (eql :over (cdr (assoc (intern "KIND" :libactr/server-test) slots))))
        (is (eq (intern "GO" :libactr/server-test)
                (cdr (assoc (intern "VERB" :libactr/server-test) slots))))
        (is (eq (intern "WENT" :libactr/server-test)
                (cdr (assoc (intern "PAST" :libactr/server-test) slots))))
        (is (eql 0 (cdr (assoc (intern "JUNK" :libactr/server-test) slots))))))))
