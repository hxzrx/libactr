;;;; src/proxy.lisp — the thin front proxy (Phase 13, spec §5.2 protocol 5).
;;;; Same package as cluster.lisp (:libactr/cluster). 5 endpoints; routes by
;;;; student_id/session_id from the redis routing table; forwards the RAW
;;;; request body via dexador and passes worker statuses through verbatim
;;;; (dexador signals on 4xx/5xx — unwrapped via its condition readers); one
;;;; re-resolve+retry on transport failure (takeover-transparent continuation).
;;;; /engine/v1/student/mastery is computed HERE from redis (location-free — no
;;;; worker involved). NO global mutable state: everything on the tutor-proxy
;;;; instance; dispatch via libactr/server's tutor-acceptor (per-instance table).
;;;; Phase 15: routes and forwards both carry the /engine/v1 prefix, mirroring
;;;; src/http-api.lisp — clients see ONE wire contract whether they dial a
;;;; worker directly or through this proxy.
(in-package :libactr/cluster)

(defun %libactr-version ()
  "The libactr system's version string (libactr.asd's :version), via ASDF
component-version. Phase 15: read ONCE per tutor-proxy construction and
cached in the instance's version slot — /engine/v1/health serves it from
there (no per-request ASDF access). Local mirror of libactr/server's internal
helper of the same name (not exported; the same discipline as the %jsonable
mirror of its json-encode below)."
  (asdf:component-version (asdf:find-system "libactr")))

(defclass tutor-proxy ()
  ((acceptor :accessor proxy-acceptor :initform nil)
   ;; [brief defect, run-evidenced: PORT was a :reader — with the default
   ;; :port 0 (OS-assigned) the slot stays 0 and (proxy-port p) tells callers
   ;; to dial port 0. Accessor, and make-tutor-proxy writes the ACCEPTOR's
   ;; bound port back into the slot after hunchentoot:start.]
   (port :accessor proxy-port :initarg :port :initform 0)
   (redis-host :reader proxy-redis-host :initarg :redis-host :initform "127.0.0.1")
   (redis-port :reader proxy-redis-port :initarg :redis-port :initform 6379)
   ;; [controller-mandated (Task 10 review ruling, applied Task 11): the default
   ;; prefix must be the managers' "libactr:cluster:" (colon) — a proxy created
   ;; WITHOUT :prefix must still see the routing table the managers write. This
   ;; initform was "libactr/cluster:" (slash) at review time (the ruling's premise
   ;; had it as colon already); normalized with the constructor default below.]
   (prefix :reader proxy-prefix :initarg :prefix :initform "libactr:cluster:")
   (kt-params :reader proxy-kt-params :initarg :kt-params :initform (libactr:make-kt-params))
   (forward-timeout :reader proxy-forward-timeout :initarg :forward-timeout :initform 5)
   ;; Review F8: the proxy reads each forwarded body into memory before
   ;; forwarding — cap it (bytes; nil = unlimited), same policy as the workers.
   (max-body-size :reader proxy-max-body-size :initarg :max-body-size :initform 65536)
   (conn :accessor proxy-conn :initform nil)
   ;; Controller-mandated (Task 8 ruling, same as the manager/store): this ONE
   ;; lazy cl-redis connection is multiplexed by hunchentoot's per-connection
   ;; handler threads — single-socket, not thread-safe — so all proxy redis
   ;; use is serialized under this per-instance lock.
   (redis-lock :reader proxy-redis-lock
               :initform (bt2:make-lock :name "proxy-redis"))
   ;; Phase 15: the engine version reported by the proxy's /engine/v1/health
   ;; (same source and caching discipline as tutor-server's version slot).
   (version :reader proxy-version :initarg :version :initform (%libactr-version))
   (rr :accessor proxy-rr :initform 0))
  (:documentation "Front-door proxy. Holds its own redis connection + a
round-robin cursor for worker selection at session start."))

(defun tutor-proxy-p (x)
  "Type predicate for tutor-proxy (defclass does not auto-generate -p)."
  (typep x 'tutor-proxy))

(defmacro with-proxy-redis ((p) &body body)
  "Ensure PROXY's lazy cl-redis connection and dynamically bind
redis:*connection* to it for BODY (mirror of the manager's with-cluster-redis
— cl-redis refuses to connect when *connection* is set, so connect runs under
a nil rebind). BODY runs under the proxy's redis LOCK (Task 8 ruling): the
connection is single-socket and hunchentoot is thread-per-connection; the
lock serializes the lazy connect and every command."
  (let ((pp (gensym)))
    `(let ((,pp ,p))
       (bt2:with-lock-held ((proxy-redis-lock ,pp))
         (let* ((conn (or (proxy-conn ,pp)
                          (setf (proxy-conn ,pp)
                                (let ((redis:*connection* nil))
                                  (redis:connect :host (proxy-redis-host ,pp)
                                                 :port (proxy-redis-port ,pp)))))))
           (let ((redis:*connection* conn)) ,@body))))))

;; --- json helpers (local: libactr/server's json-encode is not exported) --------

(defun %jsonable (x)
  "plist tree -> yason-encodable (mirror of libactr/server's recursive jsonify)."
  (cond
    ((null x) nil)
    ((eq x t) t)
    ((symbolp x) (string-downcase (symbol-name x)))
    ((and (consp x)
          (loop :for (k v) :on x :by #'cddr :always (keywordp k)))
     (let ((h (make-hash-table :test 'equal)))
       (loop :for (k v) :on x :by #'cddr
             :do (setf (gethash (string-downcase (symbol-name k)) h) (%jsonable v)))
       h))
    ((listp x) (mapcar #'%jsonable x))
    (t x)))

(defun %json (plist)
  (with-output-to-string (s) (yason:encode (%jsonable plist) s)))

(defun %respond (body status)
  (setf (hunchentoot:content-type*) "application/json")
  (setf (hunchentoot:return-code*) status)
  body)

(defun %raw-body ()
  (or (hunchentoot:raw-post-data :request hunchentoot:*request* :force-text t) ""))

(defun %proxy-body-ok-p (p raw)
  "Review F8: RAW (the already-read forward body) within the proxy's
max-body-size (the workers enforce their own cap on arrival)."
  (let ((limit (proxy-max-body-size p)))
    (or (null limit) (<= (length raw) limit))))

;; --- forwarding ----------------------------------------------------------------

;; [brief defect, run-evidenced: the brief's typecase tested (vector …) FIRST,
;; but a STRING IS A VECTOR — every string body (all of them; dexador decodes
;; text/* bodies) fell into babel:octets-to-string, whose TYPE-ERROR the
;; catch-all swallowed as :transport. The worker's access log showed the
;; forwarded request answered 200 while the proxy returned "worker
;; unreachable". string branch first.]
(defun %octets-or-string (b)
  (typecase b
    (string b)
    (vector (babel:octets-to-string b :encoding :utf-8))
    (t b)))

(defun %forward-post (url body timeout)
  "POST BODY to URL; returns (values body-string status) with worker statuses
passed through verbatim, or (values nil :transport) on a transport-level
failure (connection refused / timeout / reset). TIMEOUT bounds both the
connect and the read (dexador kwargs :connect-timeout/:read-timeout,
source-verified; defaults are 10s)."
  (handler-case
      (multiple-value-bind (b s) (dex:post url :content body :keep-alive nil
                                           :connect-timeout timeout
                                           :read-timeout timeout)
        (values (%octets-or-string b) s))
    (dex:http-request-failed (c)
      (values (%octets-or-string (dex:response-body c))
              (dex:response-status c)))
    (error () (values nil :transport))))

(defun proxy-live-workers (p)
  "((id host port) ...) — same shape as cluster-live-workers, off the proxy's
own connection."
  (with-proxy-redis (p)
    (loop :for id :in (redis:red-smembers (uiop:strcat (proxy-prefix p) "workers"))
          :for meta := (redis:red-get (uiop:strcat (proxy-prefix p) "worker:" id))
          :when meta
            :collect (let ((a (yason:parse meta :object-as :alist)))
                       (list id (cdr (assoc "host" a :test #'string=))
                             (cdr (assoc "port" a :test #'string=)))))))

(defun proxy-worker-url (p id)
  "http://host:port for a registered worker id, or nil when its lease metadata
is gone (dead)."
  (with-proxy-redis (p)
    (let ((meta (redis:red-get (uiop:strcat (proxy-prefix p) "worker:" id))))
      (when meta
        (let ((a (yason:parse meta :object-as :alist)))
          (format nil "http://~a:~a"
                  (cdr (assoc "host" a :test #'string=))
                  (cdr (assoc "port" a :test #'string=))))))))

;; --- endpoint handlers ----------------------------------------------------------

(defun %proxy-forward-session (p endpoint sid raw)
  "Resolve sess:<sid> -> worker, forward; on transport failure re-resolve ONCE
(takeover may have moved the route) and retry; unrouted -> 404; still dead
-> 503.

[brief defect, probe-evidenced ((getf '(\"w1\" 1) 0) => NIL — the Task 9
defect class, repeated by the brief's skeleton in BOTH route lookups here):
getf is a property-list accessor; multiple-value-list is positional. As
written, EVERY routed step/end read nil and 404'd. nth-value 0 instead.]"
  (flet ((try (id)
           (let ((url (and id (proxy-worker-url p id))))
             (if url
                 (multiple-value-bind (body status)
                     (%forward-post (uiop:strcat url "/engine/v1/session/" endpoint) raw
                                    (proxy-forward-timeout p))
                   (if (eq status :transport) nil (values body status id)))
                 nil))))
    (let ((first-id (with-proxy-redis (p)
                      (nth-value 0 (cluster-route-get
                                    (uiop:strcat (proxy-prefix p) "sess:" sid))))))
      (cond
        ((null first-id) (values "{\"error\":\"unknown session_id\"}" 404))
        (t (multiple-value-bind (body status used-id) (try first-id)
             (declare (ignore used-id))
             (cond
               (status (values body status))
               (t ;; transport failure: re-resolve once
                (let ((second-id (with-proxy-redis (p)
                                   (nth-value 0
                                     (cluster-route-get
                                      (uiop:strcat (proxy-prefix p) "sess:" sid))))))
                  (if (and second-id (not (string= second-id first-id)))
                      (multiple-value-bind (b2 s2) (try second-id)
                        (if s2 (values b2 s2)
                            (values "{\"error\":\"worker unreachable\"}" 503)))
                      (values "{\"error\":\"worker unreachable\"}" 503)))))))))))

(defun %proxy-start (p)
  (let ((raw (%raw-body)))
    (unless (%proxy-body-ok-p p raw)
      (return-from %proxy-start
        (%respond "{\"error\":\"request body too large\"}" 413)))
    (let* ((alist (yason:parse raw :object-as :alist))
           (student-id (cdr (assoc "student_id" alist :test #'string=)))
           (live (proxy-live-workers p)))
    (cond
      ((null live) (%respond "{\"error\":\"no live workers\"}" 503))
      (t (let* ((sticky (and student-id
                              (nth-value 0
                                (with-proxy-redis (p)
                                  (cluster-route-get
                                   (uiop:strcat (proxy-prefix p) "student:" student-id))))))
                ;; A5 (phase 14): an existing LIVE route for this student wins
                ;; over round-robin — the worker's own same-student
                ;; idempotency returns the active session, so a repeat start
                ;; can no longer open a second session on another worker and
                ;; overwrite the student route. A dead/stale route (worker
                ;; metadata gone) falls through to round-robin.
                (w (or (and sticky
                            (find sticky live :key #'first :test #'string=))
                       ;; [hardening, Task 8 ruling: the round-robin cursor
                       ;; bumps under the instance lock — thread-per-connection
                       ;; handlers would otherwise race the incf.]
                       (nth (mod (bt2:with-lock-held
                                     ((proxy-redis-lock p))
                                   (incf (proxy-rr p)))
                                 (length live))
                            live)))
                (url (format nil "http://~a:~a/engine/v1/session/start"
                             (second w) (third w))))
           (multiple-value-bind (body status)
               (%forward-post url raw (proxy-forward-timeout p))
             ;; [brief defect, probe-evidenced ((= :transport 200) signals):
             ;; a live-by-lease worker that is unreachable at forward time
             ;; returns status :transport, and the brief's (= status 200)
             ;; would signal on the keyword. Map transport -> 503 first.]
             (if (eq status :transport)
                 (%respond "{\"error\":\"worker unreachable\"}" 503)
                 (progn
                   (when (and (= status 200) student-id)
                     (let ((sid (cdr (assoc "session_id"
                                            (yason:parse body :object-as :alist)
                                            :test #'string=))))
                       (when sid
                         (with-proxy-redis (p)
                           (cluster-route-set (uiop:strcat (proxy-prefix p) "sess:" sid)
                                              (first w))
                           (cluster-route-set (uiop:strcat (proxy-prefix p) "student:" student-id)
                                              (first w))
                           (redis:red-sadd (uiop:strcat (proxy-prefix p) "worker-sess:" (first w))
                                           sid)))))
                   (%respond body status))))))))))

(defun %proxy-step (p)
  (let* ((raw (%raw-body)))
    (if (%proxy-body-ok-p p raw)
        (let* ((alist (yason:parse raw :object-as :alist))
               (sid (cdr (assoc "session_id" alist :test #'string=))))
          (multiple-value-bind (body status)
              (%proxy-forward-session p "step" sid raw)
            (%respond body status)))
        (%respond "{\"error\":\"request body too large\"}" 413))))

(defun %proxy-end (p)
  (let* ((raw (%raw-body)))
    (if (%proxy-body-ok-p p raw)
        (let* ((alist (yason:parse raw :object-as :alist))
               (sid (cdr (assoc "session_id" alist :test #'string=))))
          (multiple-value-bind (body status)
              (%proxy-forward-session p "end" sid raw)
            (%respond body status)))
        (%respond "{\"error\":\"request body too large\"}" 413))))

(defun %proxy-mastery (p)
  ;; Location-free (spec §5.2 protocol 5): computed HERE from the redis event
  ;; log — no worker involvement, works across failovers. The redis-event-log
  ;; opens its OWN connection (not the proxy's shared one).
  (let ((student-id (or (hunchentoot:get-parameter "student_id") "")))
    (let ((ss (libactr:start-student-session
               student-id
               :event-log (libactr:make-redis-event-log
                           :key (libactr/server:student-events-key student-id)
                           :host (proxy-redis-host p) :port (proxy-redis-port p)))))
      (unwind-protect
           (let* ((events (libactr:log-all-events (libactr:student-session-log ss)))
                  (mastery (and events (libactr:compute-mastery
                                        events :kt-params (proxy-kt-params p)))))
             (if (null events)
                 (%respond "{\"error\":\"unknown student_id\"}" 404)
                 (%respond
                  (%json (list :student_id student-id
                               :kc (mapcar (lambda (x)
                                             (list :kc (libactr/server:kc->json (getf x :kc))
                                                   :correct (getf x :correct)
                                                   :total (getf x :total)
                                                   :accuracy (getf x :accuracy)
                                                   :p_l (getf x :p-l)))
                                           mastery)))
                  200)))
        (libactr:disconnect-log (libactr:student-session-log ss))))))

(defun %proxy-health (p)
  "Liveness + live-worker count + the engine version (Phase 15 — additive:
status/workers keep their shape, mirroring tutor-server's health)."
  (%respond (%json (list :status "ok"
                         :workers (length (proxy-live-workers p))
                         :version (proxy-version p)))
            200))

;; --- lifecycle ---------------------------------------------------------------------

(defun proxy-handlers (p)
  "The proxy's 5 dispatch entries — same /engine/v1 routes the workers serve
(Phase 15), so the proxy is a drop-in front door."
  (list (cons "/engine/v1/session/start" (lambda () (%proxy-start p)))
        (cons "/engine/v1/session/step"   (lambda () (%proxy-step p)))
        (cons "/engine/v1/session/end"    (lambda () (%proxy-end p)))
        (cons "/engine/v1/student/mastery" (lambda () (%proxy-mastery p)))
        (cons "/engine/v1/health" (lambda () (%proxy-health p)))))

(defun make-tutor-proxy (&key (port 0) (redis-host "127.0.0.1") (redis-port 6379)
                           (prefix "libactr:cluster:") (kt-params (libactr:make-kt-params))
                           (forward-timeout 5) (max-body-size 65536))
  "Create + start the front proxy on PORT (0 = OS-assigned; read it back via
proxy-port). Reuses libactr/server's tutor-acceptor subclass for per-instance
dispatch (no global hunchentoot:*dispatch-table*). FORWARD-TIMEOUT bounds each
outbound forward's connect+read. KT-PARAMS is validated at construction
(review F9: check-kt-params fail-fast — the location-free mastery folds with
it). MAX-BODY-SIZE (review F8) caps accepted request bodies in bytes
(413 beyond; nil = unlimited)."
  (let ((params (or kt-params (libactr:make-kt-params))))
    (libactr:check-kt-params params "make-tutor-proxy :kt-params")
    (let ((p (make-instance 'tutor-proxy :port port :redis-host redis-host
                            :redis-port redis-port :prefix prefix
                            :kt-params params
                            :forward-timeout forward-timeout
                            :max-body-size max-body-size)))
      (setf (proxy-acceptor p)
            (make-instance 'libactr/server:tutor-acceptor :port port
                           :taskmaster (make-instance
                                        'hunchentoot:one-thread-per-connection-taskmaster)))
      (setf (libactr/server:tutor-acceptor-dispatch-table (proxy-acceptor p))
            (mapcar (lambda (spec)
                      (hunchentoot:create-prefix-dispatcher (car spec) (cdr spec)))
                    (proxy-handlers p)))
      (hunchentoot:start (proxy-acceptor p))
      ;; write the OS-assigned port back (see the port slot note above)
      (setf (proxy-port p) (hunchentoot:acceptor-port (proxy-acceptor p)))
      p)))

(defun stop-tutor-proxy (p)
  "Stop the acceptor and disconnect redis. Safe multiple times."
  (when (proxy-acceptor p) (hunchentoot:stop (proxy-acceptor p) :soft t))
  (setf (proxy-acceptor p) nil)
  (when (proxy-conn p)
    ;; under the lock: an in-flight handler thread may hold the connection
    (bt2:with-lock-held ((proxy-redis-lock p))
      (let ((redis:*connection* (proxy-conn p)))
        (ignore-errors (redis:disconnect)))
      (setf (proxy-conn p) nil)))
  p)
