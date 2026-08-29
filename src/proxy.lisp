;;;; src/proxy.lisp — the thin front proxy (Phase 13, spec §5.2 protocol 5).
;;;; Same package as cluster.lisp (:mtt/cluster). 5 endpoints; routes by
;;;; student_id/session_id from the redis routing table; forwards the RAW
;;;; request body via dexador and passes worker statuses through verbatim
;;;; (dexador signals on 4xx/5xx — unwrapped via its condition readers); one
;;;; re-resolve+retry on transport failure (takeover-transparent continuation).
;;;; /student/mastery is computed HERE from redis (location-free — no worker
;;;; involved). NO global mutable state: everything on the tutor-proxy
;;;; instance; dispatch via mtt/server's tutor-acceptor (per-instance table).
(in-package :mtt/cluster)

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
   ;; prefix must be the managers' "mtt:cluster:" (colon) — a proxy created
   ;; WITHOUT :prefix must still see the routing table the managers write. This
   ;; initform was "mtt/cluster:" (slash) at review time (the ruling's premise
   ;; had it as colon already); normalized with the constructor default below.]
   (prefix :reader proxy-prefix :initarg :prefix :initform "mtt:cluster:")
   (kt-params :reader proxy-kt-params :initarg :kt-params :initform (mtt:make-kt-params))
   (forward-timeout :reader proxy-forward-timeout :initarg :forward-timeout :initform 5)
   (conn :accessor proxy-conn :initform nil)
   ;; Controller-mandated (Task 8 ruling, same as the manager/store): this ONE
   ;; lazy cl-redis connection is multiplexed by hunchentoot's per-connection
   ;; handler threads — single-socket, not thread-safe — so all proxy redis
   ;; use is serialized under this per-instance lock.
   (redis-lock :reader proxy-redis-lock
               :initform (bordeaux-threads:make-lock "proxy-redis"))
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
       (bordeaux-threads:with-lock-held ((proxy-redis-lock ,pp))
         (let* ((conn (or (proxy-conn ,pp)
                          (setf (proxy-conn ,pp)
                                (let ((redis:*connection* nil))
                                  (redis:connect :host (proxy-redis-host ,pp)
                                                 :port (proxy-redis-port ,pp)))))))
           (let ((redis:*connection* conn)) ,@body))))))

;; --- json helpers (local: mtt/server's json-encode is not exported) --------

(defun %jsonable (x)
  "plist tree -> yason-encodable (mirror of mtt/server's recursive jsonify)."
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
                     (%forward-post (uiop:strcat url "/session/" endpoint) raw
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
  (let* ((raw (%raw-body))
         (alist (yason:parse raw :object-as :alist))
         (student-id (cdr (assoc "student_id" alist :test #'string=)))
         (live (proxy-live-workers p)))
    (cond
      ((null live) (%respond "{\"error\":\"no live workers\"}" 503))
      (t (let* (;; [hardening, Task 8 ruling: the round-robin cursor bumps under
                ;; the instance lock — thread-per-connection handlers would
                ;; otherwise race the incf.]
                (idx (bordeaux-threads:with-lock-held ((proxy-redis-lock p))
                       (incf (proxy-rr p))))
                (w (nth (mod idx (length live)) live))
                (url (format nil "http://~a:~a/session/start"
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
                   (%respond body status)))))))))

(defun %proxy-step (p)
  (let* ((raw (%raw-body))
         (alist (yason:parse raw :object-as :alist))
         (sid (cdr (assoc "session_id" alist :test #'string=))))
    (multiple-value-bind (body status)
        (%proxy-forward-session p "step" sid raw)
      (%respond body status))))

(defun %proxy-end (p)
  (let* ((raw (%raw-body))
         (alist (yason:parse raw :object-as :alist))
         (sid (cdr (assoc "session_id" alist :test #'string=))))
    (multiple-value-bind (body status)
        (%proxy-forward-session p "end" sid raw)
      (%respond body status))))

(defun %proxy-mastery (p)
  ;; Location-free (spec §5.2 protocol 5): computed HERE from the redis event
  ;; log — no worker involvement, works across failovers. The redis-event-log
  ;; opens its OWN connection (not the proxy's shared one).
  (let ((student-id (or (hunchentoot:get-parameter "student_id") "")))
    (let ((ss (mtt:start-student-session
               student-id
               :event-log (mtt:make-redis-event-log
                           :key (format nil "mtt:student:~a:events" student-id)
                           :host (proxy-redis-host p) :port (proxy-redis-port p)))))
      (unwind-protect
           (let* ((events (mtt:log-all-events (mtt:student-session-log ss)))
                  (mastery (and events (mtt:compute-mastery
                                        events :kt-params (proxy-kt-params p)))))
             (if (null events)
                 (%respond "{\"error\":\"unknown student_id\"}" 404)
                 (%respond
                  (%json (list :student_id student-id
                               :kc (mapcar (lambda (x)
                                             (list :kc (princ-to-string (getf x :kc))
                                                   :correct (getf x :correct)
                                                   :total (getf x :total)
                                                   :accuracy (getf x :accuracy)
                                                   :p_l (getf x :p-l)))
                                           mastery)))
                  200)))
        (mtt:disconnect-log (mtt:student-session-log ss))))))

(defun %proxy-health (p)
  (%respond (%json (list :status "ok" :workers (length (proxy-live-workers p)))) 200))

;; --- lifecycle ---------------------------------------------------------------------

(defun proxy-handlers (p)
  (list (cons "/session/start" (lambda () (%proxy-start p)))
        (cons "/session/step"   (lambda () (%proxy-step p)))
        (cons "/session/end"    (lambda () (%proxy-end p)))
        (cons "/student/mastery" (lambda () (%proxy-mastery p)))
        (cons "/health" (lambda () (%proxy-health p)))))

(defun make-tutor-proxy (&key (port 0) (redis-host "127.0.0.1") (redis-port 6379)
                           (prefix "mtt:cluster:") (kt-params (mtt:make-kt-params))
                           (forward-timeout 5))
  "Create + start the front proxy on PORT (0 = OS-assigned; read it back via
proxy-port). Reuses mtt/server's tutor-acceptor subclass for per-instance
dispatch (no global hunchentoot:*dispatch-table*). FORWARD-TIMEOUT bounds each
outbound forward's connect+read."
  (let ((p (make-instance 'tutor-proxy :port port :redis-host redis-host
                          :redis-port redis-port :prefix prefix
                          :kt-params (or kt-params (mtt:make-kt-params))
                          :forward-timeout forward-timeout)))
    (setf (proxy-acceptor p)
          (make-instance 'mtt/server:tutor-acceptor :port port
                         :taskmaster (make-instance
                                      'hunchentoot:one-thread-per-connection-taskmaster)))
    (setf (mtt/server:tutor-acceptor-dispatch-table (proxy-acceptor p))
          (mapcar (lambda (spec)
                    (hunchentoot:create-prefix-dispatcher (car spec) (cdr spec)))
                  (proxy-handlers p)))
    (hunchentoot:start (proxy-acceptor p))
    ;; write the OS-assigned port back (see the port slot note above)
    (setf (proxy-port p) (hunchentoot:acceptor-port (proxy-acceptor p)))
    p))

(defun stop-tutor-proxy (p)
  "Stop the acceptor and disconnect redis. Safe multiple times."
  (when (proxy-acceptor p) (hunchentoot:stop (proxy-acceptor p) :soft t))
  (setf (proxy-acceptor p) nil)
  (when (proxy-conn p)
    ;; under the lock: an in-flight handler thread may hold the connection
    (bordeaux-threads:with-lock-held ((proxy-redis-lock p))
      (let ((redis:*connection* (proxy-conn p)))
        (ignore-errors (redis:disconnect)))
      (setf (proxy-conn p) nil)))
  p)
