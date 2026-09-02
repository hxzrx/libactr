;;;; tests/suite.lisp — FiveAM master suite
(defpackage :libactr/test
  (:use :cl :5am :libactr))

(in-package :libactr/test)

(def-suite :libactr :description "libactr engine tests")

;; 每个 test-* 文件用 (in-suite :libactr) 加入。run 入口:
(defun run-all () (5am:run! :libactr))
