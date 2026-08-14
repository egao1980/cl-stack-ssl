;;;; Phase 2: load smoke — cl+ssl must dlopen an OpenSSL and the package
;;;; surface must be intact. Overlay binaries are exercised by publish-oci +
;;;; smoke-clean-container.sh; this validates the Lisp side on stock system
;;;; OpenSSL across the OS matrix.

(setf *debugger-hook*
      (lambda (c h)
        (declare (ignore h))
        (format *error-output* "~&UNHANDLED: ~A~%" c)
        (uiop:quit 1)))

(setf asdf:*compile-file-failure-behaviour* :warn)

(defun call-with-ci-muffles (fn)
  #+sbcl
  (handler-bind ((sb-ext:defconstant-uneql
                  (lambda (c)
                    (let ((r (find-restart 'continue c)))
                      (when r (invoke-restart r))))))
    (funcall fn))
  #-sbcl
  (funcall fn))

(call-with-ci-muffles (lambda () (asdf:load-system "cl-repository-client")))
(cl-repository-client/asdf-integration:configure-asdf-source-registry)
(call-with-ci-muffles
 (lambda ()
   (cl-repository-client/asdf-integration:load-system-init-files)))

(call-with-ci-muffles
 (lambda ()
   (asdf:load-system "cl-stack-ssl")
   (multiple-value-bind (ok version)
       (uiop:symbol-call :cl-stack-ssl :ensure-ssl)
     (unless ok
       (error "ensure-ssl returned NIL"))
     (format t "~&; ci: cl-stack-ssl loaded (tracks OpenSSL ~a)~%" version))))

(format t "~&; ci: tests ok~%")
(uiop:quit 0)
