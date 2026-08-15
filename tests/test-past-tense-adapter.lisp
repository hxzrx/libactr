;;;; tests/test-past-tense-adapter.lisp — past-tense adapter tests (Phase 10).
;;;; Suite :mtt/server (defined in tests/test-server.lisp). Drives the 6-branch
;;;; routing matrix (spec §5) through the programmatic tutor-server API; the
;;;; over-HTTP e2e is added in Task 4.
(defpackage :mtt/past-tense-adapter-test
  (:use :cl :5am))
(in-package :mtt/past-tense-adapter-test)
(in-suite :mtt/server)

(defun %server ()
  "tutor-server with past-tense model+adapter registered under \"pt\"."
  (let ((s (mtt/server:start-tutor-server :port 0 :start-acceptor-p nil)))
    (mtt/server:register-model s "pt"
                               (mtt/past-tense-adapter:build-past-tense-model)
                               (mtt/past-tense-adapter:make-past-tense-adapter))
    s))

(defun %step (s sid verb answer)
  (nth-value 0
    (mtt/server:server-step-session s sid
      `(("type" . "answer") ("value" . ,answer)))))

(defun %answer (s student verb answer)
  "Start a fresh session for VERB, answer ANSWER, end the session, and return
the trace-result's status + production name (what the 6-branch assertions
destructure). DEVIATION from the brief's helper (returned the bare
trace-result, which the test bodies then destructured as (status name)):
wrapping in %status-name fixes the shape, and server-end-session is REQUIRED —
server-start-session is idempotent on a student's ACTIVE session, so an
un-ended first session would swallow the next same-student start (the kc test
answers two problems as one student)."
  (let ((sid (mtt/server:server-start-session s student verb "pt")))
    (multiple-value-prog1 (%status-name (%step s sid verb answer))
      (mtt/server:server-end-session s sid))))

(defun %status-name (r)
  (values (mtt:trace-result-status r)
          (and (mtt:trace-result-production r)
               (symbol-name (mtt:production-name (mtt:trace-result-production r))))))

(test past-tense-adapter.on-path-irregular
  "go -> went: on-path via RETRIEVE-IRREGULAR, done in ONE step (terminal list)."
  (let ((s (%server)))
    (unwind-protect
         (multiple-value-bind (status name) (%answer s "p1" "go" "went")
           (is (eq :on-path status))
           (is (string= "RETRIEVE-IRREGULAR" name))
           (is (mtt:step-done? (mtt/past-tense-adapter:make-past-tense-adapter)
                               (nth-value 0
                                 (let ((sid (mtt/server:server-start-session s "p1b" "go" "pt")))
                                   (%step s sid "go" "went")))
                               nil)))
      (mtt/server:stop-tutor-server s))))

(test past-tense-adapter.on-path-regular
  "walk -> walked: on-path via APPLY-REGULAR, done."
  (let ((s (%server)))
    (unwind-protect
         (multiple-value-bind (status name) (%answer s "p2" "walk" "walked")
           (is (eq :on-path status))
           (is (string= "APPLY-REGULAR" name)))
      (mtt/server:stop-tutor-server s))))

(test past-tense-adapter.on-path-no-change-irregular
  "put -> put: no-change irregular takes the WORD-FACT path (correct form =
stem), NOT the no-ed bug (that is regular-only). Regression guard for spec §11.3."
  (let ((s (%server)))
    (unwind-protect
         (multiple-value-bind (status name) (%answer s "p3" "put" "put")
           (is (eq :on-path status))
           (is (string= "RETRIEVE-IRREGULAR" name)))
      (mtt/server:stop-tutor-server s))))

(test past-tense-adapter.buggy-over-regularize
  "go -> goed: off-path-buggy via BUGGY-OVER-REGULARIZE, feedback present."
  (let ((s (%server)))
    (unwind-protect
         (multiple-value-bind (status name) (%answer s "p4" "go" "goed")
           (is (eq :off-path-buggy status))
           (is (string= "BUGGY-OVER-REGULARIZE" name)))
      (mtt/server:stop-tutor-server s))))

(test past-tense-adapter.buggy-no-ed
  "play -> play (unchanged regular verb): off-path-buggy via BUGGY-NO-ED."
  (let ((s (%server)))
    (unwind-protect
         (multiple-value-bind (status name) (%answer s "p5" "play" "play")
           (is (eq :off-path-buggy status))
           (is (string= "BUGGY-NO-ED" name)))
      (mtt/server:stop-tutor-server s))))

(test past-tense-adapter.buggy-vowel-analogy
  "bring -> brang (analogy to sing/sang): off-path-buggy via BUGGY-VOWEL-ANALOGY."
  (let ((s (%server)))
    (unwind-protect
         (multiple-value-bind (status name) (%answer s "p6" "bring" "brang")
           (is (eq :off-path-buggy status))
           (is (string= "BUGGY-VOWEL-ANALOGY" name)))
      (mtt/server:stop-tutor-server s))))

(test past-tense-adapter.unclassified-off-path
  "go -> wented (matches no bug table): :off-path. Also: go -> go (unchanged
irregular) is unclassified per spec §4."
  (let ((s (%server)))
    (unwind-protect
         (progn
           (is (eq :off-path (%answer s "p7" "go" "wented")))
           (is (eq :off-path (%answer s "p8" "go" "go"))))
      (mtt/server:stop-tutor-server s))))

(test past-tense-adapter.kc-routes-by-verb-class
  "The SAME action type routes to different KCs by problem variable: go/went
logs an :irregular-retrieval kc-event, walk/walked an :regular-inflection one
(read from the student's shared log via server-student-mastery)."
  (let ((s (%server)))
    (unwind-protect
         (progn
           (%answer s "p9" "go" "went")
           (%answer s "p9" "walk" "walked")
           (let ((m (mtt/server:server-student-mastery s "p9")))
             (is (= 2 (length m)))
             (is (find :irregular-retrieval m :key (lambda (e) (getf e :kc))))
             (is (find :regular-inflection m :key (lambda (e) (getf e :kc))))))
      (mtt/server:stop-tutor-server s))))
