;;;; tests/test-adapter-base.lisp — standard-domain-adapter plumbing helpers (Phase 8).
;;;; Suite :mtt/server (defined in tests/test-server.lisp). Pure helper tests: a
;;;; minimal test-only subclass + synthetic sessions; no real model/HTTP.
(in-package :mtt/server-test)
(in-suite :mtt/server)

(defclass test-adapter (standard-domain-adapter) ())

(defun make-test-adapter (&optional (terminal "DONE"))
  (make-instance 'test-adapter
                 :model-package (find-package :mtt/server-test)
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
    (is (eq (adapter-intern a "FOO") (intern "FOO" :mtt/server-test)))))

(test adapter-fact.builds-interned-chunk-values-pass-through
  (let* ((a (make-test-adapter))
         (c (adapter-fact a "T1" :n1 1 :n2 2)))
    (is (eq (chunk-isa c) (intern "T1" :mtt/server-test)))
    (is (eql 1 (cdr (assoc (intern "N1" :mtt/server-test) (chunk-slots c)))))
    (is (eql 2 (cdr (assoc (intern "N2" :mtt/server-test) (chunk-slots c)))))))

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
      (is (eq (car (first prime)) (intern "RETRIEVAL" :mtt/server-test)))
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
