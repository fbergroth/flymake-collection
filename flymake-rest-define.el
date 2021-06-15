;;; flymake-rest-define.el --- A macro to simplify checker creation -*- lexical-binding: t -*-

;;; Commentary:

;; This file provides a macro, adapted heavily from [[https://github.com/karlotness/flymake-quickdef/blob/150c5839768a3d32f988f9dc08052978a68f2ad7/flymake-quickdef.el][flymake-quickdef]],
;;
;; A shallow fork of [[https://github.com/karlotness/flymake-quickdef][flymake-quickdef]] supporting more flycheck like features.
;; TODO: Finish

;; TODO: license

;;; Code:

(require 'flymake)

;;;###autoload
(defvar-local flymake-rest-define--procs nil)

(defmacro flymake-rest-define (name &optional docstring &rest defs)
  "Quickly define a backend for use with Flymake.
This macro creates a new function NAME which is suitable for use with the
variable `flymake-diagnostic-functions'.

DEFS is a plist of values used to setup the backend. The only required fields
in DEFS is :command and :error-parser.

Available Variables

fmqd-source, fmqd-temp-file, fmdq-temp-dir, fmqd-context. TODO: Document.

Body Definitions

The overall execution of the produced function first makes use of (1)
:write-type, (2) :source-inplace, (3) :pre-let, and (3) :pre-check. Next
a process is created using (4) :command. Once the process is finished
:error-parser is called (until it returns nil) to get the next diagnostic
which is then provided to flymake. (5) :title if provided is used to
suffix the messages for each diagnostic.

:write-type specifies how the process for flymake should recieve the input.
It should be one of 'pipe or 'file (defaulting to 'pipe). When set to file
a temporary file will be created copying the contents of the current-buffer.
The variable fmqd-temp-file and fmqd-temp-dir will be bound in the body
of the rest of the keywords that provide access to the temp-file. When set
to pipe after the process has been started all of the current buffers input
will be passed to the process through standard-input.

:source-inplace is a boolean that sets fmqd-temp-dir to the current working
directory. By default this is nil and the temp-file used for :write-type 'file
will be set to a folder in the systems temporary directory.

:pre-let is a `let*' form that is assigned after any backend-agnostic let
forms have been setup.

:pre-check is a lisp form that will be executed immeadiately before any pending
checker processes are killed and a new process is begun. It can check conditions
to ensure launching the checker program is possible. If something is wrong it
should signal an error.

:command is a lip form which evaluates to a list of strings that will be used to
start the checker process. It should be suitable for use as the :command argument
to the `make-process' function.

:error-parser is a lisp-form that should, each time it is evaluated, return the
next diagnostic from the checker output. The result should be a value that can
be passed to the `flymake-make-diagnostic' function. Once there're no more
diagnostics to parse this form should evaluate to nil."
  (declare (indent defun) (doc-string 2))
  (unless lexical-binding
    (error "Need lexical-binding for flymake-rest-define (%s)" name))
  (or (stringp docstring)
      (setq defs (cons docstring defs)
            docstring nil))
  (dolist (elem '(:command :error-parser))
    (unless (plist-get defs elem)
      (error "Missing flymake backend definition `%s'" elem)))
  (let* ((write-type (or (eval (plist-get defs :write-type)) 'pipe))
         (source-inplace (plist-get defs :source-inplace))
         (temp-dir-symb (intern "fmqd-temp-dir"))
         (temp-file-symb (intern "fmqd-temp-file"))
         (err-symb (intern "fmqd-err"))
         (diags-symb (intern "diags"))
         (proc-symb (intern "proc"))
         (source-symb (intern "fmqd-source"))
         (current-diags-symb (intern "diag"))
         (cleanup-form (when (and (eq write-type 'file)
                                  (not source-inplace))
                         `((delete-directory ,temp-dir-symb t))))
         (not-obsolete-form `((eq ,proc-symb (plist-get (buffer-local-value 'flymake-rest-define--procs ,source-symb) ',name)))))
    ;; Sanitise parsed inputs from `defs'.
    (unless (memq write-type '(file pipe nil))
      (error "Invalid `:write-type' value `%s'" write-type))

    `(defun ,name (report-fn &rest _args)
       ,docstring
       (let* ((,source-symb (current-buffer))
              (fmqd-context nil)
              ,@(when (eq write-type 'file)
                  `((,temp-dir-symb
                     ,@(let ((forms (append (when source-inplace
                                              `((when-let ((file (buffer-file-name)))
                                                  (file-name-directory file))
                                                default-directory))
                                            '((make-temp-file "flymake-" t)))))
                         (if (> (length forms) 1)
                             `((or ,@forms))
                           forms)))
                    (,temp-file-symb
                     (concat
                      (file-name-as-directory ,temp-dir-symb)
                      (concat ".flymake_"
                              (file-name-nondirectory (or (buffer-file-name)
                                                          (buffer-name))))))))
              ,@(plist-get defs :pre-let))
         ;; With vars defined, do :pre-check.
         ,@(when-let ((pre-check (plist-get defs :pre-check)))
             `((condition-case ,err-symb
                   (progn ,pre-check)
                 (error ,@cleanup-form
                        (signal (car ,err-symb) (cdr ,err-symb))))))
         ;; Kill any running (obsolete) processes for current checker and buffer.
         (let ((,proc-symb (plist-get flymake-rest-define--procs ',name)))
           (when (process-live-p ,proc-symb)
             (kill-process ,proc-symb)
             (flymake-log :debug "Killing earlier checker process %s" ,proc-symb)))

         ;; Kick-start checker process.
         (save-restriction
           (widen)
           ;; Write the current file out before starting checker.
           ,@(when (eq write-type 'file)
               `((write-region nil nil ,temp-file-symb nil 'silent)))
           (let (proc)
             (setq proc
                   (make-process
                    :name ,(concat (symbol-name name) "-flymake")
                    :noquery t
                    :connection-type 'pipe
                    :buffer (generate-new-buffer ,(concat " *" (symbol-name name) "-flymake*"))
                    :command
                    (let ((cmd ,(plist-get defs :command)))
                      (prog1 cmd
                        (flymake-log :debug "Checker command is %s" cmd)))
                    :sentinel
                    (lambda (,proc-symb _event)
                      (unless (process-live-p ,proc-symb)
                        (unwind-protect
                            (if ,@not-obsolete-form
                                (with-current-buffer ,source-symb
                                  ;; First read diagnostics from process buffer referencing the source buffer.
                                  (let ((,diags-symb nil) ,current-diags-symb)
                                    ;; Widen the source buffer to ensure `flymake-diag-region' is correct.
                                    (save-restriction
                                      (widen)
                                      (with-current-buffer (process-buffer ,proc-symb)
                                        (goto-char (point-min))
                                        (save-match-data
                                          (while (setq ,current-diags-symb ,(plist-get defs :error-parser))
                                            (let* ((diag-beg (nth 1 ,current-diags-symb))
                                                   (diag-end (nth 2 ,current-diags-symb))
                                                   (diag-type (nth 3 ,current-diags-symb)))
                                              (if (and (integer-or-marker-p diag-beg)
                                                       (integer-or-marker-p diag-end))
                                                  ;; Skip any diagnostics with a type of nil
                                                  ;; This makes it easier to filter some out.
                                                  (when diag-type
                                                    ;; Include the checker name/title in the message.
                                                    ,@(when (plist-get defs :title)
                                                        `((setf (nth 4 ,current-diags-symb)
                                                                (concat (nth 4 ,current-diags-symb)
                                                                        ,(concat
                                                                          " ("
                                                                          (propertize (plist-get defs :title)
                                                                                      'face 'flymake-rest-checker)
                                                                          ")")))))

                                                    (push (apply #'flymake-make-diagnostic ,current-diags-symb)
                                                          ,diags-symb))
                                                (with-current-buffer ,source-symb
                                                  (flymake-log :error "Got invalid buffer position %s or %s in %s"
                                                               diag-beg diag-end ,proc-symb))))))))
                                    ;; Pass reports back to the callback-function when still not-obsolete.
                                    (if ,@not-obsolete-form
                                        (progn
                                          (let ((status (process-exit-status ,proc-symb)))
                                            (when (and (eq (length ,diags-symb) 0)
                                                       (not (eq status 0)))
                                              (flymake-log :warning
                                                           "Checker gave no diagnostics but had a non-zero exit status %d\nStderr:" status
                                                           (with-current-buffer (process-buffer ,proc-symb)
                                                             (format "%s" (buffer-substring-no-properties
                                                                           (point-min) (point-max)))))))
                                          (funcall report-fn (nreverse ,diags-symb)))
                                      ;; In case the check was cancelled after processing began but before it finished.
                                      (flymake-log :warning "Canceling obsolete check %s" ,proc-symb)))
                                  (flymake-log :warning "Canceling obsolete check %s" ,proc-symb)))
                          ;; Finished linting, cleanup any temp-files and then kill proc buffer.
                          ,@cleanup-form
                          (kill-buffer (process-buffer ,proc-symb)))))))
             ;; Push the new-process to the process to the process alist.
             (setq flymake-rest-define--procs
                   (plist-put flymake-rest-define--procs ',name ,proc-symb))
             ;; If piping, send data to the process.
             ,@(when (eq write-type 'pipe)
                 `((process-send-region proc (point-min) (point-max))
                   (process-send-eof proc)))
             ,proc-symb))))))

(defun flymake-rest-parse-json (output)
  "Helper for `flymake-rest-define' to parse JSON output OUTPUT.

Adapted from `flycheck-parse-json'. This reads a bunch of JSON-Lines
like output from OUTPUT into a list and then returns it."
  (let (objects
        (json-array-type 'list)
        (json-false nil))
    (with-temp-buffer
      (insert output)
      (goto-char (point-min))
      (while (not (eobp))
        (when (memq (char-after) '(?\{ ?\[))
          (push (json-parse-buffer
                 :object-type 'alist :array-type 'list
                 :null-object nil :false-object nil)
                objects))
        (forward-line)))
    objects))

(provide 'flymake-rest-define)