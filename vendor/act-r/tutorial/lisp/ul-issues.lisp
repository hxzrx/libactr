; ACT-R tutorial unit7 task for investigating utility
; learning modeling issues.

(defun present-choose ()
  (goal-focus (isa choose))
  (schedule-event-relative 5 "utility-learning-issues-show-result" 
                           :params (list (if (< (act-r-random 1.0) .6) 'a (if (> (act-r-random 1.0) .5) 'b nil)))
                           :output 'medium))

(defun show-result (choice)
  (set-buffer-chunk 'imaginal (list 'answer choice))
  (schedule-event-relative 2 "utility-learning-issues-choose" :output 'medium))

(add-act-r-command "utility-learning-issues-choose" 'present-choose "Function to change model's goal for utility learning issues model")
(add-act-r-command "utility-learning-issues-show-result" 'show-result "Function to set the model's imaginal buffer for utility learning issues model")

(defun finished ()
  (remove-act-r-command "utility-learning-issues-choose")
  (remove-act-r-command "utility-learning-issues-show-result"))

(load (resolve-path "act-r" "tutorial/unit7/utility-learning-issues-model.lisp"))