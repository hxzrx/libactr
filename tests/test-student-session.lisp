;;;; tests/test-student-session.lisp — student-session (Phase 5, pure)
(in-package :mtt/test)
(in-suite :mtt)

(test student-session-lifecycle
  (let ((ss (start-student-session "alice")))
    (is (student-session-p ss))
    (is (equal "alice" (student-session-student-id ss)))
    (is (eql :active (student-session-status ss)))
    (is (null (student-session-sessions ss)))
    (let ((summary (end-student-session ss)))
      (is (eql :ended (student-session-status ss)))
      (is (equal :ended (getf summary :status))))))

(test student-session-shared-log-across-problems
  "Two cognitive-sessions under one student share ONE event log: events from
both carry the same student-id, and seq is monotonic across problems."
  (let* ((md (addition-compiled-model))
         (ss (start-student-session "alice"))
         (log (student-session-log ss))
         (c1 (start-session md "alice" "p1" :event-log log))
         (c2 (start-session md "alice" "p2" :event-log log)))
    (register-cognitive-session ss c1)
    (register-cognitive-session ss c2)
    (step-session c1 (make-step-intent :assignments '((goal sum five) (goal count zero))))
    (step-session c2 (make-step-intent :assignments '((goal sum five) (goal count zero))))
    (is (= 2 (log-last-seq log)))
    (let ((events (log-all-events log)))
      (is (= 2 (length events)))
      (is (every (lambda (e) (equal "alice" (mtt:log-event-student-id e))) events))
      (is (not (equal (mtt:log-event-session-id (first events))
                      (mtt:log-event-session-id (second events)))))))
  ;; sessions registered for bookkeeping
  (let ((ss (start-student-session "bob")))
    (register-cognitive-session ss (start-session (addition-compiled-model) "bob" "p1"
                                                   :event-log (student-session-log ss)))
    (is (= 1 (length (student-session-sessions ss))))))

(test compute-mastery-pure-aggregation
  "compute-mastery groups synthetic events by kc and reports correct/total/accuracy."
  (flet ((ev (kc correct)
           (make-log-event :seq 0 :kc-event (make-kc-event :kc kc :correct-p correct))))
    (let ((mastery (compute-mastery
                    (list (ev 'add  t) (ev 'add t) (ev 'add nil)   ; add: 2/3
                          (ev 'sub  t)                               ; sub: 1/1
                          (make-log-event :seq 0 :kc-event nil))))) ; unclassified → skipped
      (is (= 2 (length mastery)))
      (let ((add (find 'add mastery :key (lambda (p) (getf p :kc)))))
        (is (= 2 (getf add :correct)))
        (is (= 3 (getf add :total)))
        (is (< 0.66 (getf add :accuracy) 0.67)))
      (let ((sub (find 'sub mastery :key (lambda (p) (getf p :kc)))))
        (is (= 1 (getf sub :correct)))
        (is (= 1 (getf sub :total)))
        (is (= 1.0d0 (getf sub :accuracy)))))))
