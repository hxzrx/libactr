;;; Simple test to show timing differences for strings
;;; returned from get-articulation-time based on the
;;; settings of the new parameters.

#| These are the results of running the test-syllable-count function.

> (test-syllable-count)
:syllable-rate parameter is the default of: 0.15
:char-per-syllable parameter is the default of: 3

special is set with register-articulation-time to .333
zzzzzzz is not in the syllable table
String: "a"
table split
NIL   NIL   : 150ms
T     NIL   : 150ms
NIL   T     : 150ms
T     T     : 150ms
String: "special"
table split
NIL   NIL   : 333ms
T     NIL   : 333ms
NIL   T     : 333ms
T     T     : 333ms
String: "through"
table split
NIL   NIL   : 350ms
T     NIL   : 150ms
NIL   T     : 350ms
T     T     : 150ms
String: "zzzzzzz"
table split
NIL   NIL   : 350ms
T     NIL   : 350ms
NIL   T     : 350ms
T     T     : 350ms
String: "through zzzzzzz"
table split
NIL   NIL   : 750ms
T     NIL   : 750ms
NIL   T     : 850ms
T     T     : 650ms
String: "special zzzzzzz"
table split
NIL   NIL   : 750ms
T     NIL   : 750ms
NIL   T     : 833ms
T     T     : 833ms
special is set with register-articulation-time to .333
zzzzzzz is set with register-syllable-count to 1
String: "a"
table split
NIL   NIL   : 150ms
T     NIL   : 150ms
NIL   T     : 150ms
T     T     : 150ms
String: "special"
table split
NIL   NIL   : 333ms
T     NIL   : 333ms
NIL   T     : 333ms
T     T     : 333ms
String: "through"
table split
NIL   NIL   : 350ms
T     NIL   : 150ms
NIL   T     : 350ms
T     T     : 150ms
String: "zzzzzzz"
table split
NIL   NIL   : 350ms
T     NIL   : 150ms
NIL   T     : 350ms
T     T     : 150ms
String: "through zzzzzzz"
table split
NIL   NIL   : 750ms
T     NIL   : 750ms
NIL   T     : 850ms
T     T     : 450ms
String: "special zzzzzzz"
table split
NIL   NIL   : 750ms
T     NIL   : 750ms
NIL   T     : 833ms
T     T     : 633ms
T
|#




(clear-all)
(require-extra "syllable-count")

(defun test-syllable-count ()
  (model-output ":syllable-rate parameter is the default of: ~f" (get-parameter-value :syllable-rate))
  (model-output ":char-per-syllable parameter is the default of: ~d~%" (get-parameter-value :char-per-syllable))
  (model-output "special is set with register-articulation-time to .333~%zzzzzzz is not in the syllable table")
  (when (get-syllable-count "zzzzzzz")
    (remove-syllable-count "zzzzzzz"))
  (dolist (w (list "a" "special" "through" "zzzzzzz" "through zzzzzzz" "special zzzzzzz"))
    (model-output "String: ~s~%table split" w)
    (dolist (split (list nil t)) 
      (dolist (table (list nil t))
        (reset)
        (set-parameter-value :use-syllable-table table)
        (set-parameter-value :split-vocal-strings split)
        (register-articulation-time "special" .333)
        (model-output "~5s ~5s : ~dms" table split (get-articulation-time w t)))))
  (model-output "special is set with register-articulation-time to .333~%zzzzzzz is set with register-syllable-count to 1")
  (register-syllable-count "zzzzzzz" 1)
  (dolist (w (list "a" "special" "through" "zzzzzzz" "through zzzzzzz" "special zzzzzzz"))
    (model-output "String: ~s~%table split" w)
    (dolist (split (list nil t)) 
      (dolist (table (list nil t))
        (reset)
        (set-parameter-value :use-syllable-table table)
        (set-parameter-value :split-vocal-strings split)
        (register-articulation-time "special" .333)
        (model-output "~5s ~5s : ~dms" table split (get-articulation-time w t)))))
  (remove-syllable-count "zzzzzzz")
  t)


(define-model test)

