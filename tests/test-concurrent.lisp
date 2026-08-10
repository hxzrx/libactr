;;;; tests/test-concurrent.lisp — Phase 4 concurrent-isolation proof (bordeaux APIv2).
;;;; Proves the multi-user-safety invariant under real concurrency: N threads, each
;;;; with its OWN cognitive-session, sharing ONE read-only model-definition, with
;;;; zero cross-talk and the model left unchanged. The mtt CORE has no thread code
;;;; — this test validates that the structural invariant holds under concurrency.
(in-package :mtt/test)
(in-suite :mtt)

(test concurrent-sessions-share-readonly-model-with-no-crosstalk
  "N threads each run an independent cognitive-session against the SAME compiled
   model-definition. Each traces an on-path 'start'. Every thread must see its
   own correct independent result; the shared model is unchanged afterward."
  (let* ((md (addition-compiled-model))
         (n 8)
         (prod-before (mapcar #'production-name (model-definition-productions md))))
    (let ((threads
            (loop repeat n collect
                  (bt:make-thread
                   (lambda ()
                     (let* ((s (start-session md (gensym) (gensym)))
                            (r (step-session s (make-step-intent
                                                :assignments '((goal sum five) (goal count zero))))))
                       (list :status (trace-result-status r)
                             :path (session-path s)
                             :sum (chunk-slot (buffer-chunk (session-state s) 'goal) 'sum))))))))
      (let ((results (mapcar #'bt:join-thread threads)))
        (is (= n (length results)))
        (dolist (r results)
          (is (eq :on-path (getf r :status)))
          (is (equal '(initialize-addition) (getf r :path)))
          (is (equal 'five (getf r :sum))))
        ;; the shared model-definition is unchanged (read-only sharing)
        (is (equal prod-before (mapcar #'production-name (model-definition-productions md))))))))
