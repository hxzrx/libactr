;;;; tests/test-event-log.lisp — Phase 4 event-log unit tests.
(in-package :mtt/test)
(in-suite :mtt)

(test log-append-stores-events-and-last-seq
  "log-append stores events in order; log-last-seq / log-all-events reflect them.
   Empty log has last-seq 0."
  (let ((log (make-event-log)))
    (is (eql 0 (log-last-seq log)))
    (let ((e1 (make-log-event :seq 1 :student-id 'alice))
          (e2 (make-log-event :seq 2 :student-id 'alice)))
      (log-append log e1)
      (log-append log e2)
      (is (eql 2 (log-last-seq log)))
      (is (equal (list e1 e2) (log-all-events log))))))

(test log-events-since-returns-post-window
  "log-events-since returns only events with seq > the given seq (the post-checkpoint
   window / mastery-replay set)."
  (let ((log (make-event-log)))
    (loop for s from 1 to 4
          do (log-append log (make-log-event :seq s :student-id 'bob)))
    (is (null (log-events-since log 4)))
    (is (equal '(3 4) (mapcar #'log-event-seq (log-events-since log 2))))))

(test event-log-serialize-roundtrip-is-lossless
  "serialize-event-log -> deserialize-event-log yields a log whose events equal
   the originals field-for-field (seq/student-id/kc-event/intent/result)."
  (let* ((log (make-event-log))
         (k (make-kc-event :kc 'add :correct-p t :production 'initialize-addition :kind :correct))
         (e (make-log-event :seq 1 :timestamp 123 :student-id 'cara
                            :session-id 's1 :problem-id 'p1
                            :kc-event k :intent-summary '((goal sum five))
                            :result-summary '(:on-path initialize-addition nil 0))))
    (log-append log e)
    (let ((restored (deserialize-event-log (serialize-event-log log))))
      (is (= 1 (length (log-all-events restored))))
      (let ((r (first (log-all-events restored))))
        (is (eql 1 (log-event-seq r)))
        (is (eql 123 (log-event-timestamp r)))
        (is (eq 'cara (log-event-student-id r)))
        (is (eq 'add (kc-event-kc (log-event-kc-event r))))
        (is (eq t (kc-event-correct-p (log-event-kc-event r))))
        (is (equal '((goal sum five)) (log-event-intent-summary r)))
        (is (equal '(:on-path initialize-addition nil 0) (log-event-result-summary r)))))))
