;;;; tests/test-session.lisp — Phase 4 cognitive-session unit tests.
(in-package :mtt/test)
(in-suite :mtt)

(defun fresh-addition-session ()
  "A cognitive-session over the addition model: student alice, problem p1."
  (start-session (addition-compiled-model) 'alice 'p1))

(test start-session-initializes-goal-from-model-initial-goal
  "start-session seeds the goal buffer from a deep copy of model-initial-goal
   (isolation: each session owns its chunk). Status active, counts zero."
  (let ((s (fresh-addition-session)))
    (is (eq 'add (chunk-isa (buffer-chunk (session-state s) 'goal))))
    (is (equal 'five (chunk-slot (buffer-chunk (session-state s) 'goal) 'arg1)))
    (is (eq :active (session-status s)))
    (is (eql 0 (session-step-count s)))
    (is (eql 0 (log-last-seq (session-log s))))))

(test start-session-goal-is-isolated-from-model
  "The session's goal chunk is a COPY, not the shared model-initial-goal object."
  (let* ((md (addition-compiled-model))
         (model-goal (model-definition-initial-goal md))
         (s (start-session md 'alice 'p1)))
    (is (not (eq model-goal (buffer-chunk (session-state s) 'goal))))))

(test step-session-on-path-advances-state-path-and-appends-event
  "A 'start' intent on the fresh goal is on-path: step-session advances state/path,
   bumps step-count, appends a log-event carrying the kc-event; returns trace-result."
  (let* ((s (fresh-addition-session))
         (intent (make-step-intent :assignments '((goal sum five) (goal count zero))))
         (r (step-session s intent)))
    (is (eq :on-path (trace-result-status r)))
    (is (equal '(initialize-addition) (session-path s)))
    (is (equal 'five (chunk-slot (buffer-chunk (session-state s) 'goal) 'sum)))
    (is (eql 1 (session-step-count s)))
    (let ((ev (first (log-all-events (session-log s)))))
      (is (eql 1 (log-event-seq ev)))
      (is (eq 'alice (log-event-student-id ev)))
      (is (eq 'initialize-addition (kc-event-kc (log-event-kc-event ev))))
      (is (eq t (kc-event-correct-p (log-event-kc-event ev)))))))

(test step-session-equals-direct-trace-step
  "WRAPPER PURITY (regression guard): step-session's trace-result equals a direct
   trace-step on the same (model, state, path, intent), field for field. The
   wrapper changes no diagnosis — it only holds state + appends an event."
  (let* ((md (addition-compiled-model))
         (intent (make-step-intent :assignments '((goal sum five) (goal count zero))))
         ;; mirror start-session's initial state (arg1/arg2, no sum slot)
         (direct-state (let ((st (make-buffer-state)))
                         (setf (buffer-chunk st 'goal)
                               (make-chunk :isa 'add :slots '((arg1 . five) (arg2 . two))))
                         st))
         (direct (trace-step md direct-state nil intent))
         (wrapped (step-session (fresh-addition-session) intent)))
    (is (eq (trace-result-status direct) (trace-result-status wrapped)))
    (is (eq (production-name (trace-result-production direct))
            (production-name (trace-result-production wrapped))))
    (is (equal (trace-result-next-path direct) (trace-result-next-path wrapped)))
    (is (equal (chunk-slot (buffer-chunk (trace-result-next-state direct) 'goal) 'sum)
               (chunk-slot (buffer-chunk (trace-result-next-state wrapped) 'goal) 'sum)))))

(test step-session-off-path-leaves-state-unchanged-but-appends-event
  "An off-path step does not advance state/path but still appends an event."
  (let* ((s (fresh-addition-session))
         (intent (make-step-intent :assignments '((goal sum banana))))
         (r (step-session s intent)))
    (is (eq :off-path (trace-result-status r)))
    (is (null (session-path s)))
    (is (eql 1 (session-step-count s)))
    (is (eq :unclassified
            (kc-event-kind (log-event-kc-event (first (log-all-events (session-log s)))))))))

(test end-session-marks-ended-and-summarizes
  "end-session sets status :ended, takes a final checkpoint, returns a summary
   with step/event counts."
  (let ((s (fresh-addition-session)))
    (step-session s (make-step-intent :assignments '((goal sum five) (goal count zero))))
    (let ((summary (end-session s)))
      (is (eq :ended (session-status s)))
      (is (eql 1 (getf summary :step-count)))
      (is (eql 1 (getf summary :event-count)))
      (is (equal '(initialize-addition) (getf summary :path))))))

(test cognitive-session-p-recognizes-session
  "cognitive-session-p is a real defined predicate (defclass does not auto-make -p)."
  (let ((s (fresh-addition-session)))
    (is (cognitive-session-p s))
    (is (not (cognitive-session-p 42)))
    (is (not (cognitive-session-p nil)))))

(test model-definition-is-not-mutated-by-tracing
  "READ-ONLY SHARING: many sessions tracing against one shared model-definition
   never mutate it — productions/chunk-types/chunks counts are unchanged."
  (let* ((md (addition-compiled-model))
         (prod-before (length (model-definition-productions md)))
         (ct-before (hash-table-count (model-definition-chunk-types md)))
         (chunks-before (hash-table-count (model-definition-chunks md))))
    (dotimes (i 5)
      (let ((s (start-session md (gensym) (gensym))))
        (step-session s (make-step-intent :assignments '((goal sum five) (goal count zero))))))
    (is (eql prod-before (length (model-definition-productions md))))
    (is (eql ct-before (hash-table-count (model-definition-chunk-types md))))
    (is (eql chunks-before (hash-table-count (model-definition-chunks md))))))
