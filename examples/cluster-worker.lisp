;;;; examples/cluster-worker.lisp — phase 13 cluster worker bootstrap.
;;;; DUAL USE: the deployment reference AND the e2e test's worker program.
;;;; Launch (e2e does exactly this):
;;;;   sbcl --non-interactive \
;;;;     --eval '(ql:quickload :libactr/cluster)' \
;;;;     --eval '(ql:quickload :libactr/subtraction-adapter)' \
;;;;     --load <this file> \
;;;;     --eval '(libactr/cluster-worker:main :port 8801 :redis-port 6390 :worker-id "w1")'
;;;; The worker registers the subtraction model under "sub" (all workers in a
;;;; cluster MUST register the same model table — deployment guide, spec §13.6),
;;;; runs its tutor-server with redis event logs, joins the cluster, and blocks.
(defpackage :libactr/cluster-worker
  (:use :cl)
  (:export #:main))
(in-package :libactr/cluster-worker)

(defun main (&key (port 0) (redis-host "127.0.0.1") (redis-port 6379)
              (worker-id (error "worker-id is required"))
              (heartbeat-ttl 2) (heartbeat-interval 1)
              (scan-interval 1) (takeover-interval 1)
              (model-id "sub"))
  "Start one cluster worker and BLOCK. Port 0 = OS-assigned. Intervals default
to test-tight values; production deployments pass saner ones (e.g. ttl 15 /
intervals 5/2/5 — see README's cluster guide)."
  ;; Defense-in-depth only (phase 14 A2 root fix landed in make-session-id:
  ;; time+sub-second+gensym components): burning a worker-id-derived gensym
  ;; offset additionally staggers the per-image counter. Harmless; kept.
  (loop :repeat (mod (sxhash worker-id) 4096) :do (gensym))
  (let* ((server (libactr/server:start-tutor-server
                  :port port :start-acceptor-p t
                  :redis-config (list :host redis-host :port redis-port)))
         (manager (libactr/cluster:make-cluster-manager
                   :server server :worker-id worker-id
                   :redis-host redis-host :redis-port redis-port
                   :heartbeat-ttl heartbeat-ttl :heartbeat-interval heartbeat-interval
                   :scan-interval scan-interval :takeover-interval takeover-interval)))
    (libactr/server:register-model server model-id
                               (libactr/subtraction-adapter:build-subtraction-model)
                               (libactr/subtraction-adapter:make-subtraction-adapter))
    (libactr/cluster:start-cluster-manager manager)
    (format t "~&libactr/cluster-worker ~a up (acceptor port ~a, redis ~a:~a)~%"
            worker-id (hunchentoot:acceptor-port (libactr/server:server-acceptor server))
            redis-host redis-port)
    (force-output)
    (loop :do (sleep 1))))            ; killed externally (supervisor / test)
