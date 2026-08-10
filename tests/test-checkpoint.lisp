;;;; tests/test-checkpoint.lisp — Phase 4 checkpoint/restore unit tests.
(in-package :mtt/test)
(in-suite :mtt)

(test checkpoint-restore-roundtrips-solving-state
  "checkpoint-session then restore-from-checkpoint reproduces state/path/step-count/
   metadata; status resets to :active so the session can continue."
  (let* ((md (addition-compiled-model))
         (s (start-session md 'alice 'p1 :session-id 's1 :model-id 'm1)))
    (step-session s (make-step-intent :assignments '((goal sum five) (goal count zero))))
    (let ((restored (restore-from-checkpoint (checkpoint-session s) md)))
      (is (eq 's1 (session-id restored)))
      (is (eq 'alice (session-student-id restored)))
      (is (eq 'm1 (session-model-id restored)))
      (is (equal '(initialize-addition) (session-path restored)))
      (is (eql 1 (session-step-count restored)))
      (is (equal 'five (chunk-slot (buffer-chunk (session-state restored) 'goal) 'sum)))
      (is (eq :active (session-status restored))))))

(test checkpoint-restore-yields-isolated-state
  "Restored state is a fresh copy: writes on it do not affect the original session."
  (let* ((md (addition-compiled-model))
         (s (start-session md 'alice 'p1)))
    (step-session s (make-step-intent :assignments '((goal sum five) (goal count zero))))
    (let ((restored (restore-from-checkpoint (checkpoint-session s) md)))
      (setf (buffer-chunk (session-state restored) 'goal) nil)
      (is (not (null (buffer-chunk (session-state s) 'goal)))))))

(test recovery-drops-post-checkpoint-solving-state-but-keeps-full-log
  "Recovery (spec §5.4): a checkpoint after step 1 restores step-1 solving state
   (step 2's advance is DROPPED — student redoes), while the retained event log
   still holds BOTH steps (mastery recomputation is lossless). Step 2 is made
   on-path by priming retrieval (consumer responsibility, like the tutor)."
  (let* ((md (addition-compiled-model))
         (s (start-session md 'alice 'p1))
         (log (session-log s)))
    ;; step 1: initialize (no retrieval needed)
    (step-session s (make-step-intent :assignments '((goal sum five) (goal count zero))))
    (let ((cp (checkpoint-session s)))              ; checkpoint after step 1
      ;; prime retrieval so step 2 (increment-sum) matches: goal sum=five, retrieval number=five next=six
      (setf (buffer-chunk (session-state s) 'retrieval)
            (make-chunk :isa 'number :slots '((number . five) (next . six))))
      ;; step 2 happens AFTER the checkpoint -> its solving-state advance is lost on recovery
      (let ((r2 (step-session s (make-step-intent :assignments '((goal sum six))))))
        (is (eq :on-path (trace-result-status r2)) "step 2 must advance (sanity)"))
      ;; simulate crash: rebuild from checkpoint, pass the retained FULL log
      (let ((recovered (restore-from-checkpoint cp md log)))
        ;; solving state is checkpoint-time (step 1): path single, step-count 1, sum=five
        (is (equal '(initialize-addition) (session-path recovered)))
        (is (eql 1 (session-step-count recovered)))
        (is (equal 'five (chunk-slot (buffer-chunk (session-state recovered) 'goal) 'sum)))
        ;; but the log retains BOTH steps (mastery recomputation lossless)
        (is (eql 2 (length (log-all-events log))))
        (is (equal '(1 2) (mapcar #'log-event-seq (log-all-events log))))))))
