;;;; src/http-api.lisp — HTTP handlers (5 endpoints) + JSON + error codes (Phase 5)
;;;
;;; Two layers:
;;;   * PURE LOGIC functions handle-start / handle-step / handle-end /
;;;     handle-mastery / handle-health. Each takes (server parsed-body) [health
;;;     takes only server; mastery takes (server student-id)] and returns
;;;     (values response-plist http-status). The plist keys are Lisp keywords
;;;     (compared with eq via getf in tests); the JSON encoder below converts
;;;     them to lowercase-string JSON keys. These are tested DIRECTLY by
;;;     tests/test-server.lisp's http.* tests.
;;;   * THIN HUNCHENTOOT WRAPPERS (make-handlers / install-handlers!) that read
;;;     *request*, parse JSON, dispatch to the logic fns, encode JSON, set the
;;;     HTTP status. Not exercised by unit tests (would need a live acceptor);
;;;     their logic is the test-covered pure fns.
;;;
;;; NO global mutable state in this file (no defvar/defparameter). Each handler
;;; closes over the tutor-server instance passed to make-handlers /
;;; install-handlers!.
(in-package :mtt/server)
(ql:quickload :yason :silent t)

;;; --- JSON helpers ------------------------------------------------------------
;;;
;;; yason's default *symbol-key-encoder* is ENCODE-SYMBOL-KEY-ERROR, which
;;; signals on any symbol key (regular keyword like :session_id OR a barred
;;; keyword like :|session_id|). redis-store.lisp sidesteps this by using plain
;;; STRING keys. Here we keep keyword keys in the response plists (so tests can
;;; use (getf resp :session_id)) and bind both *symbol-key-encoder* (for keys)
;;; and *symbol-encoder* (for symbol values like the :on-path status keyword)
;;; to a lowercase-name converter inside json-encode. This produces JSON keys
;;; matching the snake_case / lowercase conventions of the response shape and
;;; JSON string values for status symbols.

(defun json-decode (string)
  "Parse STRING (a JSON document) into an alist with string keys."
  (let ((yason:*parse-object-as* :alist))
    (yason:parse string)))

(defun json-encode (plist)
  "Encode PLIST (with keyword or string keys) as a JSON object string. Keyword
keys are lowercased (e.g. :SESSION_ID -> \"session_id\"); keyword values are
likewise stringified and lowercased (e.g. :ON-PATH -> \"on-path\"). nil values
become JSON null; t becomes JSON true."
  (let ((yason:*symbol-key-encoder*
          (lambda (k) (string-downcase (symbol-name k))))
        (yason:*symbol-encoder*
          (lambda (s) (string-downcase (symbol-name s)))))
    (with-output-to-string (s)
      (yason:encode-plist plist s))))

(defun kc->json (kc)
  "Stringify a KC symbol at the data boundary. princ-to-string is used (rather
than symbol-name) so that future non-symbol KCs (e.g. strings) are handled."
  (princ-to-string kc))

(defun trace-result->response-plist (result adapter session)
  "Build the step-response plist from a trace-result plus its adapter/session
context. Includes the KC of the first event (the step's KC), aggregate mastery
from the student's full event log, and the domain-specific done flag."
  (let* ((kc-event (first (mtt:trace-result-events result)))
         (mastery (mtt:compute-mastery
                   (mtt:log-all-events (mtt:session-log session)))))
    (list :status (mtt:trace-result-status result)
          :production (let ((p (mtt:trace-result-production result)))
                        (and p (mtt:production-name p)))
          :feedback (mtt:trace-result-feedback result)
          :kc (and kc-event
                   (mtt:kc-event-kc kc-event)
                   (kc->json (mtt:kc-event-kc kc-event)))
          :correct (and kc-event (mtt:kc-event-correct-p kc-event))
          :mastery (mapcar (lambda (m)
                             (list :kc (kc->json (getf m :kc))
                                   :correct (getf m :correct)
                                   :total (getf m :total)
                                   :accuracy (getf m :accuracy)))
                           mastery)
          :done (mtt:step-done? adapter result session))))

;;; --- handler logic -----------------------------------------------------------
;;;
;;; Each handle-* returns (values response-plist http-status). Response-plist is
;;; a plist with keyword keys (JSON-encoded on the way out by the wrappers).
;;;
;;; CROSS-TASK CONTRACT NOTE (handle-step): server-step-session returns
;;;   (values trace-result adapter session) on success
;;;   (values nil          :not-found)       on unknown session-id
;;;   (values nil          :conflict)        on session already ended
;;; The sentinel keyword is the SECOND return value (in the adapter position),
;;; NOT the first. So the dispatch must inspect `adapter` (the second value),
;;; not `result` (the first, which is nil on failure). Checking the first value
;;; (as a literal `case` on `result`) silently routes both failure modes into
;;; the success branch and crashes when trace-result->response-plist is called
;;; with a nil trace-result.

(defun handle-start (server body)
  "Start a session. BODY is the decoded alist: student_id, problem_id, model_id.
Returns (values (:session_id sid :student_id sid) 200) on success, or
(values (:error \"unknown model_id\") 404) when model-id is not registered."
  (let ((student-id (cdr (assoc "student_id" body :test #'string=)))
        (problem-id (cdr (assoc "problem_id" body :test #'string=)))
        (model-id   (cdr (assoc "model_id"   body :test #'string=))))
    (cond
      ((null (gethash model-id (server-models server)))
       (values (list :error "unknown model_id") 404))
      (t (let ((sid (server-start-session server student-id problem-id model-id)))
           (values (list :session_id sid :student_id student-id) 200))))))

(defun handle-step (server body)
  "Trace one student step. BODY is the decoded alist: session_id, action.
Returns:
  (values step-response-plist 200) on success
  (values (:error \"unknown session_id\") 404) when session-id is unknown
  (values (:error \"session ended\")    409) when the session has ended
The success/error dispatch inspects the SECOND return value of
server-step-session (the adapter slot, which carries the sentinel keyword on
failure). See the contract note above."
  (let* ((session-id (cdr (assoc "session_id" body :test #'string=)))
         (action     (cdr (assoc "action"    body :test #'string=))))
    (multiple-value-bind (result adapter session)
        (server-step-session server session-id action)
      (cond
        ((eq adapter :not-found)
         (values (list :error "unknown session_id") 404))
        ((eq adapter :conflict)
         (values (list :error "session ended") 409))
        (t
         (values (trace-result->response-plist result adapter session) 200))))))

(defun handle-end (server body)
  "End a session. BODY is the decoded alist: session_id. Returns:
  (values (:ok t :summary (:step_count N :event_count N :status :ended)) 200)
  (values (:error \"unknown session_id\") 404) when session-id is unknown."
  (let ((session-id (cdr (assoc "session_id" body :test #'string=))))
    (multiple-value-bind (summary outcome)
        (server-end-session server session-id)
      (if (eq outcome :not-found)
          (values (list :error "unknown session_id") 404)
          (values (list :ok t
                        :summary (list :step_count (getf summary :step-count)
                                       :event_count (getf summary :event-count)
                                       :status (getf summary :status)))
                  200)))))

(defun handle-mastery (server student-id)
  "Aggregate mastery for a student. Returns:
  (values (:student_id sid :kc list-of-per-kc-plists) 200)
  (values (:error \"unknown student_id\") 404) when student-id is unknown."
  (multiple-value-bind (m outcome)
      (server-student-mastery server student-id)
    (if (eq outcome :not-found)
        (values (list :error "unknown student_id") 404)
        (values (list :student_id student-id
                      :kc (mapcar (lambda (x)
                                    (list :kc (kc->json (getf x :kc))
                                          :correct (getf x :correct)
                                          :total (getf x :total)
                                          :accuracy (getf x :accuracy)))
                                  m))
                200))))

(defun handle-health (server)
  "Return (values server-health-plist 200)."
  (values (server-health server) 200))

;;; --- Hunchentoot wrappers + dispatch -----------------------------------------

(defmacro with-json-response ((status-var) &body body)
  "Run BODY (which must produce (values plist status)); JSON-encode the plist,
set Content-Type to application/json, set the return-code to STATUS, return
the JSON string as the Hunchentoot handler response."
  `(multiple-value-bind (plist ,status-var) (progn ,@body)
     (setf (hunchentoot:content-type*) "application/json")
     (setf (hunchentoot:return-code*) ,status-var)
     (json-encode plist)))

(defun %read-json-body ()
  "Read the raw request body and json-decode it. Returns nil if there is no
body.

NOTE: the brief specified (raw-post-data :request *request* :force-string t).
Hunchentoot 1.3.1 (this deployment) has :FORCE-TEXT and :FORCE-BINARY, not
:FORCE-STRING; using the brief's keyword raises \"Unknown &KEY argument\" at
runtime. We use :FORCE-TEXT to coerce text/* and application/json bodies to a
string."
  (let ((raw (hunchentoot:raw-post-data :request hunchentoot:*request*
                                         :force-text t)))
    (and raw (json-decode raw))))

(defun make-handlers (server)
  "Return a list of (prefix . handler-fn) pairs for the 5 endpoints. Each
handler-fn is a Hunchentoot-compatible zero-argument function that returns the
JSON string response."
  (flet ((wrap (thunk)
           (lambda () (with-json-response (status) (funcall thunk)))))
    (list
     (cons "/session/start"
           (wrap (lambda () (handle-start server (%read-json-body)))))
     (cons "/session/step"
           (wrap (lambda () (handle-step  server (%read-json-body)))))
     (cons "/session/end"
           (wrap (lambda () (handle-end   server (%read-json-body)))))
     (cons "/student/mastery"
           (wrap (lambda ()
                   (handle-mastery server
                                   (or (hunchentoot:get-parameter "student_id")
                                       "")))))
     (cons "/health"
           (wrap (lambda () (handle-health server)))))))

(defun install-handlers! (server)
  "Register prefix dispatchers for the 5 endpoints on the server's
tutor-acceptor dispatch table. Idempotent in the sense that calling twice
replaces the table (not appending). Must be called only when the acceptor
exists (i.e. start-tutor-server was called with :start-acceptor-p t).

NOTE: Hunchentoot's stock easy-acceptor consults the GLOBAL
hunchentoot:*dispatch-table*, which would couple tutor-servers together.
server.lisp defines a tutor-acceptor subclass with a per-instance
dispatch-table slot and a specialized acceptor-dispatch-request method; we
populate that slot here. The dispatchers themselves close over the tutor-server
instance (via make-handlers), so two tutor-servers on different ports have
structurally isolated dispatch graphs (no global mutable state)."
  (setf (tutor-acceptor-dispatch-table (server-acceptor server))
        (mapcar (lambda (spec)
                  (hunchentoot:create-prefix-dispatcher (car spec) (cdr spec)))
                (make-handlers server))))
