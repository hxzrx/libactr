;;;; tests/suite.lisp — FiveAM master suite
(defpackage :mtt/test
  (:use :cl :5am :mtt))

(in-package :mtt/test)

(def-suite :mtt :description "mtt engine tests")

;; 每个 test-* 文件用 (in-suite :mtt) 加入。run 入口:
(defun run-all () (5am:run! :mtt))
