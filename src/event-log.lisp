;;;; src/event-log.lisp — authoritative append-only event log (Phase 4)
;;;; The event log is the system's source of truth: mastery (Phase 6) is a
;;;; deterministic derivation of the kc-event stream it holds. Append-only and
;;;; serializable. The in-memory log's vector is per-session PRIVATE mutable
;;;; state (held inside a cognitive-session), NOT global.
(in-package :libactr)

;; --- log-event: one record per traced step; pure data ------------------------
(defstruct log-event
  "One record per traced step — the authoritative append-only stream that
mastery/KT (compute-mastery) deterministically derives from. Pure data;
slot comments document each field."
  (seq            0 :type unsigned-byte)  ; monotonic within a session (from 1)
  (timestamp      nil)                    ; get-universal-time; informational
  (student-id     nil)
  (session-id     nil)
  (problem-id     nil)
  (kc-event       nil)                    ; Phase 3 kc-event (kc/correct-p/kind) — KT input
  (intent-summary nil)                    ; step-intent.assignments: ((buf slot val)...)
  (result-summary nil))                   ; (status production-name feedback alt-count)

(defun summarize-trace-result (r)
  "Reduce a trace-result to a pure-data summary for the event log."
  (list (trace-result-status r)
        (if (trace-result-production r)
            (production-name (trace-result-production r))
            nil)
        (trace-result-feedback r)
        (length (trace-result-alternatives r))))

;; --- protocol (generic): Phase 5 plugs a durable backend at this seam --------
(defgeneric log-append (log event)
  (:documentation "Append EVENT to LOG. Append-only: never mutates existing events."))
(defgeneric log-all-events (log)
  (:documentation "All events in seq order."))
(defgeneric log-events-since (log seq)
  (:documentation "Events with seq > SEQ (the post-checkpoint window / replay set)."))
(defgeneric log-last-seq (log)
  (:documentation "Current highest seq (0 if empty)."))
(defgeneric disconnect-log (log)
  (:documentation "Release any backend resources held by LOG (e.g. close a socket).
Idempotent. The in-memory event-log has nothing to release (default no-op)."))

;; --- in-memory implementation ------------------------------------------------
(defstruct (event-log (:constructor %make-event-log (events)))
  (events (make-array 0 :adjustable t :fill-pointer 0) :type vector))

(defun make-event-log (&optional (initial-events nil initialp))
  "New in-memory event-log, optionally seeded with INITIAL-EVENTS (in order)."
  (let ((log (%make-event-log (make-array 0 :adjustable t :fill-pointer 0))))
    (when initialp (dolist (e initial-events) (log-append log e)))
    log))

(defmethod log-append ((log event-log) (event log-event))
  (vector-push-extend event (event-log-events log))
  log)

(defmethod log-all-events ((log event-log))
  (coerce (event-log-events log) 'list))

(defmethod log-events-since ((log event-log) (seq integer))
  (loop :for e :across (event-log-events log)
        :when (> (log-event-seq e) seq) :collect e))

(defmethod log-last-seq ((log event-log))
  (let ((n (length (event-log-events log))))
    (if (zerop n) 0 (log-event-seq (aref (event-log-events log) (1- n))))))

(defmethod disconnect-log ((log event-log))
  ;; In-memory log holds no external resources.
  log)

;; --- serialization (pure data, portable) -------------------------------------
(defun serialize-kc-event (k)
  (when k
    (list :kc (kc-event-kc k)
          :correct-p (kc-event-correct-p k)
          :production (kc-event-production k)
          :kind (kc-event-kind k))))

(defun deserialize-kc-event (data)
  (when data
    (make-kc-event :kc (getf data :kc)
                   :correct-p (getf data :correct-p)
                   :production (getf data :production)
                   :kind (getf data :kind))))

(defun serialize-log-event (e)
  (list :seq (log-event-seq e)
        :timestamp (log-event-timestamp e)
        :student-id (log-event-student-id e)
        :session-id (log-event-session-id e)
        :problem-id (log-event-problem-id e)
        :kc-event (serialize-kc-event (log-event-kc-event e))
        :intent-summary (log-event-intent-summary e)
        :result-summary (log-event-result-summary e)))

(defun deserialize-log-event (data)
  (make-log-event
   :seq (getf data :seq)
   :timestamp (getf data :timestamp)
   :student-id (getf data :student-id)
   :session-id (getf data :session-id)
   :problem-id (getf data :problem-id)
   :kc-event (deserialize-kc-event (getf data :kc-event))
   :intent-summary (getf data :intent-summary)
   :result-summary (getf data :result-summary)))

(defgeneric serialize-event-log (log)
  (:documentation "Pure-data representation of LOG (list of serialized events)."))
(defgeneric deserialize-event-log (data)
  (:documentation "Rebuild an event-log from pure data."))

(defmethod serialize-event-log ((log event-log))
  (map 'list #'serialize-log-event (event-log-events log)))

(defmethod deserialize-event-log ((data list))
  (let ((log (make-event-log)))
    (dolist (e data log) (log-append log (deserialize-log-event e)))))
