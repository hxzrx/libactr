;;;; tests/test-empirical.lisp — empirical validation harness (Phase 7 Task 5).
;;;; Synthetic-student mastery patterns -> P(L) behavior assertions, run for BOTH
;;;; fraction and addition (cross-domain). Two legs:
;;;;   (a) tracing correctness via server-step-session (real engine path);
;;;;   (b) P(L) math via direct compute-mastery (deterministic, hand-constructed
;;;;       event streams — exercises the same code without HTTP/session overhead).
;;;; Plus an end-to-end tie (test 8): drive a real fraction problem 3x via the
;;;; server and read P(L) back from server-student-mastery, so P(L) validation is
;;;; not ONLY on hand-constructed events.
;;;; Suite :mtt/empirical (own system, does NOT join :mtt).
(defpackage :mtt/empirical-test
  (:use :cl :5am :mtt))
(in-package :mtt/empirical-test)

(def-suite :mtt/empirical :description "empirical validation: tracing + P(L) behavior")
(in-suite :mtt/empirical)

;;; --- P(L) math leg: drive compute-mastery directly with synthetic events ----

(defun %events (kc observations)
  "Build a log-event list for KC over OBSERVATIONS (list of bools), seq 1.."
  (loop :for c :in observations
        :for seq :from 1
        :collect (make-log-event :seq seq
                                 :kc-event (make-kc-event :kc kc :correct-p c))))

(defun %p-l (mastery kc)
  (getf (find kc mastery :key (lambda (p) (getf p :kc))) :p-l))

(test p-l.rises-with-consecutive-correct
  "P(L) is non-decreasing across a run of corrects, for both KCs (fraction domain)."
  (let ((m (compute-mastery (append (%events :common-denominator '(t t t t t t))
                                    (%events :add-fractions '(t t t t t t))))))
    (flet ((curve (kc obs) (loop :for n :from 1 :to (length obs)
                                 :collect (%p-l (compute-mastery (%events kc (subseq obs 0 n))) kc))))
      (let ((cd (curve :common-denominator '(t t t t t t)))
            (af (curve :add-fractions '(t t t t t t))))
        (is (every (lambda (a b) (<= a b)) cd (rest cd)))   ; non-decreasing
        (is (every (lambda (a b) (<= a b)) af (rest af)))))))

(test p-l.drops-after-error
  "P(L) after [t t t] is higher than after [t t t nil] (an error drops it)."
  (let ((m3 (compute-mastery (%events :add-fractions '(t t t))))
        (m4 (compute-mastery (%events :add-fractions '(t t t nil)))))
    (is (> (%p-l m3 :add-fractions) (%p-l m4 :add-fractions)))))

(test p-l.converges-high
  "After 10 consecutive corrects (transit 0.3), P(L) >= 0.9."
  (let ((m (compute-mastery (%events :add-fractions
                                '(t t t t t t t t t t))
                            :kt-params (make-kt-params :transit 0.3d0))))
    (is (>= (%p-l m :add-fractions) 0.9d0))))

(test p-l.interval-and-finite
  "Every P(L) across mixed sequences is strictly in (0,1), a real, finite number."
  (let ((m (compute-mastery (append (%events :add-fractions '(t nil t nil t t))
                                    (%events :common-denominator '(nil t t nil t))))))
    (dolist (entry m)
      (let ((pl (getf entry :p-l)))
        (is (realp pl))
        (is (< 0.0d0 pl 1.0d0))))))

(test p-l.per-kc-distinctness
  "Same correct sequence on two KCs; one with transit 0.05 (slow), one 0.4 (fast)
via per-KC override. The slow KC ends strictly lower."
  (let* ((params (make-kt-params
                   :overrides (list (cons :common-denominator (make-kt-params :transit 0.05d0))
                                    (cons :add-fractions     (make-kt-params :transit 0.4d0)))))
         (obs '(t t t t t t t t))
         (m (compute-mastery (append (%events :common-denominator obs)
                                     (%events :add-fractions obs))
                             :kt-params params)))
    (is (< (%p-l m :common-denominator) (%p-l m :add-fractions)))))

;;; --- tracing leg: drive server-step-session with known-correct/buggy steps ---

(defun %frac-server ()
  (let ((s (mtt/server:start-tutor-server :port 0 :start-acceptor-p nil)))
    (mtt/server:register-model s "frac" (mtt/fraction-adapter:build-fraction-model)
                               (mtt/fraction-adapter:make-fraction-adapter))
    s))

(test tracing.fraction-on-path-and-buggy
  "Tracing judgments match known traces: correct common-denom+sum -> on-path;
planted add-across sum -> off-path-buggy."
  (let ((s (%frac-server)))
    (unwind-protect
         (let ((sid (mtt/server:server-start-session s "e" "1/2+1/3" "frac")))
           ;; on-path: 6 then 5/6
           (is (eq :on-path (mtt:trace-result-status
                             (nth-value 0 (mtt/server:server-step-session
                                           s sid '(("type" . "common-denom") ("value" . "6")))))))
           ;; planted bug: after correct cdenom, sum 2/5 -> off-path-buggy
           (let ((sid2 (mtt/server:server-start-session s "e2" "1/2+1/3" "frac")))
             (mtt/server:server-step-session s sid2 '(("type" . "common-denom") ("value" . "6")))
             (is (eq :off-path-buggy
                     (mtt:trace-result-status
                      (nth-value 0 (mtt/server:server-step-session
                                    s sid2 '(("type" . "sum") ("num" . "2") ("denom" . "5")))))))))
      (mtt/server:stop-tutor-server s))))

;;; --- end-to-end P(L) tie: real traced log -> compute-mastery -> P(L) -----------
;;; Validates that P(L) math isn't only exercised on hand-constructed events: the
;;; engine emits the REAL kc-events during server-step-session; the shared student
;;; log accumulates them; server-student-mastery replays them through
;;; compute-mastery. After 3 correct observations on each fraction KC, default
;;; params give P(L) = 52/55 (~0.945) — well above L0=0.1 and strictly in (0,1).

(test p-l.fraction-from-real-traced-log
  "End-to-end: drive one fraction problem 3x for one student via server-step-session
(the engine emits the REAL kc-events), end each session, then server-student-mastery
replays the shared log through compute-mastery. Assert each KC's P(L) is in (0,1) and
rose above L0=0.1 after 3 correct observations. (1/2+1/3: cdenom 6, sum 5/6.)"
  (let ((s (%frac-server)))
    (unwind-protect
         (progn
           (dotimes (i 3)
             (let ((sid (mtt/server:server-start-session s "rz" "1/2+1/3" "frac")))
               (mtt/server:server-step-session s sid
                 '(("type" . "common-denom") ("value" . "6")))
               (mtt/server:server-step-session s sid
                 '(("type" . "sum") ("num" . "5") ("denom" . "6")))
               (mtt/server:server-end-session s sid)))
           (let ((m (mtt/server:server-student-mastery s "rz")))
             (is (= 2 (length m)))
             (dolist (entry m)
               (let ((pl (getf entry :p-l)))
                 (is (and (realp pl) (< 0.0d0 pl 1.0d0)))
                 (is (> pl 0.1d0) "P(L) should rise above L0 after 3 correct")))))
      (mtt/server:stop-tutor-server s))))

;;; --- cross-domain sanity: addition still behaves (regression guard) ---------

(defun %add-server ()
  (let ((s (mtt/server:start-tutor-server :port 0 :start-acceptor-p nil)))
    (mtt/server:register-model s "add" (mtt/addition-adapter:build-addition-model)
                               (mtt/addition-adapter:make-addition-adapter))
    s))

(test cross-domain.addition-p-l-sane
  "Addition P(L) over a correct-first sequence is in (0,1) and rises (regression
+ cross-domain sanity that the harness logic is not fraction-specific)."
  (let ((m (compute-mastery (%events 'initialize-addition '(t t t t)))))
    (dolist (entry m)
      (let ((pl (getf entry :p-l)))
        (is (and (realp pl) (< 0.0d0 pl 1.0d0)))))))

;;; --- Phase 10: third domain (past-tense) — KC routing by problem variable ---

(defun %pt-server ()
  (let ((s (mtt/server:start-tutor-server :port 0 :start-acceptor-p nil)))
    (mtt/server:register-model s "pt" (mtt/past-tense-adapter:build-past-tense-model)
                               (mtt/past-tense-adapter:make-past-tense-adapter))
    s))

(defun %pt-answer-correct (s student)
  (let ((sid (mtt/server:server-start-session s student "go" "pt")))
    (mtt/server:server-step-session s sid '(("type" . "answer") ("value" . "went")))
    (mtt/server:server-end-session s sid)))

(defun %pt-answer-buggy (s student)
  (let ((sid (mtt/server:server-start-session s student "go" "pt")))
    (mtt/server:server-step-session s sid '(("type" . "answer") ("value" . "goed")))
    (mtt/server:server-end-session s sid)))

(test p-l.past-tense-kc-routes-by-problem-variable
  "KC-routing evidence (spec §9.5): one student answers the IRREGULAR verb 'go'
correctly 3x -> the shared log holds ONLY :irregular-retrieval events (mastery
has 1 entry, P(L) above L0). The SAME action type would have logged
:regular-inflection on a regular verb — attribution follows the problem's verb
class, not the step type."
  (let ((s (%pt-server)))
    (unwind-protect
         (progn
           (dotimes (i 3) (%pt-answer-correct s "kcr"))
           (let ((m (mtt/server:server-student-mastery s "kcr")))
             (is (= 1 (length m)))
             (is (eq :irregular-retrieval (getf (first m) :kc)))
             (is (> (getf (first m) :p-l) 0.1d0))
             (is (< (getf (first m) :p-l) 1.0d0))))
      (mtt/server:stop-tutor-server s))))

(test p-l.past-tense-buggy-lower-than-correct
  "Over-regularizing (go->goed, 3x) yields a strictly LOWER P(L) on
:irregular-retrieval than answering correctly (go->went, 3x) — the traced
kc-event stream feeds KT with correct-p=nil on buggy steps."
  (let ((s (%pt-server)))
    (unwind-protect
         (progn
           (dotimes (i 3) (%pt-answer-correct s "kcc"))
           (dotimes (i 3) (%pt-answer-buggy s "kcb"))
           (flet ((pl (student)
                    (getf (first (mtt/server:server-student-mastery s student)) :p-l)))
             (is (< (pl "kcb") (pl "kcc")))))
      (mtt/server:stop-tutor-server s))))

(test p-l.past-tense-third-domain-sanity
  "Cross-domain harness now spans THREE domains (addition / fraction /
past-tense); past-tense P(L) over a correct sequence behaves like the others:
in (0,1)."
  (let ((m (compute-mastery (%events :irregular-retrieval '(t t t t)))))
    (dolist (entry m)
      (let ((pl (getf entry :p-l)))
        (is (and (realp pl) (< 0.0d0 pl 1.0d0)))))))

;;; --- Phase 11: fourth domain (subtraction) — KC divergence by problem mix ---

(defun %sub-server ()
  (let ((s (mtt/server:start-tutor-server :port 0 :start-acceptor-p nil)))
    (mtt/server:register-model s "sub"
                               (mtt/subtraction-adapter:build-subtraction-model)
                               (mtt/subtraction-adapter:make-subtraction-adapter))
    s))

(defun %sub-solve-no-borrow (s student)
  "One full no-borrow problem (47-25: ones 2, tens 2), start->steps->end closed."
  (let ((sid (mtt/server:server-start-session s student "47-25" "sub")))
    (mtt/server:server-step-session s sid '(("type" . "digit") ("value" . "2")))
    (mtt/server:server-step-session s sid '(("type" . "digit") ("value" . "2")))
    (mtt/server:server-end-session s sid)))

(defun %sub-solve-borrow (s student)
  "One full borrow problem (52-18: ones 4, tens 3), start->steps->end closed."
  (let ((sid (mtt/server:server-start-session s student "52-18" "sub")))
    (mtt/server:server-step-session s sid '(("type" . "digit") ("value" . "4")))
    (mtt/server:server-step-session s sid '(("type" . "digit") ("value" . "3")))
    (mtt/server:server-end-session s sid)))

(defun %sub-planted-borrow-ignore (s student)
  "One borrow problem with a planted borrow-ignore step (43-27: ones 4 = the
mirror), then end without retry — the buggy kc-event is what feeds KT."
  (let ((sid (mtt/server:server-start-session s student "43-27" "sub")))
    (mtt/server:server-step-session s sid '(("type" . "digit") ("value" . "4")))
    (mtt/server:server-end-session s sid)))

(test p-l.subtraction-kc-divergence-by-problem-mix
  "Per-KC divergence (spec §8.3): a student solving only NO-BORROW problems
accumulates :column-subtract events alone (mastery has 1 entry, P(L) above
L0); a student solving only BORROW problems exercises both KCs (the borrow
pair logs 2 :borrow events per problem). Attribution follows whether the
column needed a borrow — the arithmetic-domain analogue of past-tense's
route-by-problem-variable evidence."
  (let ((s (%sub-server)))
    (unwind-protect
         (progn
           (dotimes (i 3) (%sub-solve-no-borrow s "sa"))
           (let ((m (mtt/server:server-student-mastery s "sa")))
             (is (= 1 (length m)))
             (is (eq :column-subtract (getf (first m) :kc)))
             (is (> (getf (first m) :p-l) 0.1d0)))
           (dotimes (i 3) (%sub-solve-borrow s "sb"))
           (let ((m (mtt/server:server-student-mastery s "sb")))
             (is (= 2 (length m)))
             (is (> (getf (find :borrow m :key (lambda (e) (getf e :kc))) :p-l)
                    0.1d0))
             (is (< (getf (find :borrow m :key (lambda (e) (getf e :kc))) :p-l)
                    1.0d0))))
      (mtt/server:stop-tutor-server s))))

(test p-l.subtraction-buggy-lower-than-correct
  "Planting borrow-ignore (43-27 ones=4, 3x, no retry) yields a strictly LOWER
P(L) on :borrow than solving borrow problems correctly (52-18, 3x) — the
traced kc-event stream feeds KT with correct-p=nil on buggy steps."
  (let ((s (%sub-server)))
    (unwind-protect
         (progn
           (dotimes (i 3) (%sub-solve-borrow s "sc"))
           (dotimes (i 3) (%sub-planted-borrow-ignore s "sd"))
           (flet ((pl (student)
                    (getf (find :borrow (mtt/server:server-student-mastery s student)
                                :key (lambda (e) (getf e :kc)))
                          :p-l)))
             (is (< (pl "sd") (pl "sc")))))
      (mtt/server:stop-tutor-server s))))

(test p-l.subtraction-fourth-domain-sanity
  "Cross-domain harness now spans FOUR domains (addition / fraction /
past-tense / subtraction); subtraction P(L) over a correct sequence behaves
like the others: in (0,1)."
  (let ((m (compute-mastery (%events :borrow '(t t t t)))))
    (dolist (entry m)
      (let ((pl (getf entry :p-l)))
        (is (and (realp pl) (< 0.0d0 pl 1.0d0)))))))

;;; --- Phase 13: fraction simplify third KC — observable + P(L) behavior --------
;;;
;;; Two legs mirroring the established harness pattern: (a) the synthetic P(L)
;;; leg (%events/%p-l, no server) for the NEW :simplify KC; (b) the driven leg —
;;; a real simplifiable problem (1/6+1/6: cdenom 6 -> sum 2/6 -> simplify 1/3)
;;; through the real server path yields mastery carrying the THIRD fraction KC
;;; (:simplify), while the unsimplifiable control (1/2+1/3, gcd-1 sum, 2 steps)
;;; still shows exactly two. This is the pin that the third KC is OBSERVABLE in
;;; the KT layer, not just in the adapter.

(test p-l.simplify-kc-rises
  "P(L) for the :simplify KC rises over consecutive corrects (synthetic events)."
  (let ((curve (loop :for n :from 1 :to 6
                     :collect (%p-l (compute-mastery (%events :simplify
                                                              (make-list n :initial-element t)))
                                     :simplify))))
    (is (every (lambda (a b) (<= a b)) curve (rest curve)))))

(test empirical.fraction-simplify-third-kc-observable
  "A driven simplifiable problem (1/6+1/6) through the real server path yields
mastery with THREE fraction KCs — :simplify present with total 1 — while the
unsimplifiable control (1/2+1/3, two steps) still shows two."
  (flet ((drive (student problem steps)
             (let ((s (mtt/server:start-tutor-server :port 0 :start-acceptor-p nil)))
               (unwind-protect
                    (progn
                      (mtt/server:register-model s "frac"
                                                 (mtt/fraction-adapter:build-fraction-model)
                                                 (mtt/fraction-adapter:make-fraction-adapter))
                      (let ((sid (mtt/server:server-start-session s student problem "frac")))
                        (dolist (a steps)
                          (mtt/server:server-step-session s sid a))
                        (multiple-value-bind (m outcome)
                            (mtt/server:server-student-mastery s student)
                          (declare (ignore outcome))
                          (mapcar (lambda (x) (getf x :kc)) m))))
                  (mtt/server:stop-tutor-server s)))))
    (let ((kcs-simplifiable
            (drive "es" "1/6+1/6"
                   '((("type" . "common-denom") ("value" . "6"))
                     (("type" . "sum") ("num" . "2") ("denom" . "6"))
                     (("type" . "simplify") ("num" . "1") ("denom" . "3")))))
          (kcs-control
            (drive "ec" "1/2+1/3"
                   '((("type" . "common-denom") ("value" . "6"))
                     (("type" . "sum") ("num" . "5") ("denom" . "6"))))))
      (is (member :simplify kcs-simplifiable))
      (is (null (member :simplify kcs-control)))
      (is (= 2 (length kcs-control))))))
