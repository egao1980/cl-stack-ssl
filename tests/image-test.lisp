(in-package #:cl-stack-ssl/tests)

;;; Saved images (src/image.lisp, #23): no foreign pointer of the saving
;;; process survives into the image.

(defun %usable-global-ctx-p ()
  "An SSL object can be made on cl+ssl's global SSL_CTX."
  (cl+ssl:ensure-initialized)
  (let ((ssl (cl+ssl::ssl-new cl+ssl::*ssl-global-context*)))
    (unless (cffi:null-pointer-p ssl)
      (cl+ssl::ssl-free ssl)
      t)))

(deftest forget-ssl-state-drops-the-pointers
  (cl+ssl:ensure-initialized)
  (forget-ssl-state)
  (ok (null cl+ssl::*ssl-global-context*))
  (ok (null cl+ssl::*ssl-global-method*))
  (ok (null cl+ssl::*bio-lisp-method*))
  (ok (null *system-cert-store*))
  (ok (null cl-stack-ssl::*exported-pem-path*))
  (testing "restoring gives a working context with the trust store"
    (restore-ssl-state)
    (ok (%usable-global-ctx-p))
    (ok *system-cert-store* "the OS trust store is installed again")))

;;; A child SBCL loads this system, saves an executable and runs it. Before
;;; the hooks the saved SSL_CTX was dead in the new process and SSL_new
;;; faulted inside libssl.

(defun %loaded-system-directories ()
  (remove-duplicates
   (loop for name in (asdf:already-loaded-systems)
         for dir = (ignore-errors (asdf:system-source-directory name))
         when dir collect (namestring dir))
   :test #'string=))

(defun %saved-image-script (exe)
  "The child's script, as source text: it is read in CL-USER, where this
package's symbols would not be the ones meant."
  (let ((registry (with-standard-io-syntax
                      (prin1-to-string
                       `(:source-registry
                         ,@(mapcar (lambda (d) (list :directory d)) (%loaded-system-directories))
                         :ignore-inherited-configuration)))))
    (format nil "(require :asdf)
(asdf:initialize-source-registry '~a)
(let ((*standard-output* *error-output*))
  (asdf:load-system \"cl-stack-ssl\"))
(defun probe-main ()
  (format t \"~~a~~%\"
          (handler-case
              (progn
                (cl+ssl:ensure-initialized)
                (let ((ssl (cl+ssl::ssl-new cl+ssl::*ssl-global-context*)))
                  (if (cffi:null-pointer-p ssl)
                      \"ssl-new returned null\"
                      (progn (cl+ssl::ssl-free ssl)
                             (if cl-stack-ssl:*system-cert-store* \"ok\" \"no trust store\")))))
            (error (e) (format nil \"error: ~~a\" e))))
  (finish-output)
  (uiop:quit 0))
(setf uiop:*image-entry-point* 'probe-main)
(uiop:dump-image ~s :executable t)
"
            registry (uiop:native-namestring exe))))

(deftest saved-image-makes-ssl-objects
  #-sbcl (skip "the saved-image test starts its child with SBCL")
  #+sbcl
  (uiop:with-temporary-file (:pathname script :type "lisp" :keep nil)
    (let* ((dir (uiop:ensure-directory-pathname (uiop:pathname-directory-pathname script)))
           (exe (merge-pathnames (format nil "cl-stack-ssl-image-~36r~a"
                                         (random (expt 36 6) (make-random-state t))
                                         (if (uiop:os-windows-p) ".exe" ""))
                                 dir)))
      (with-open-file (s script :direction :output :if-exists :supersede)
        (write-string (%saved-image-script exe) s))
      (unwind-protect
          (multiple-value-bind (out err code)
              (uiop:run-program (list (uiop:native-namestring sb-ext:*runtime-pathname*)
                                      "--core" (uiop:native-namestring sb-ext:*core-pathname*)
                                      "--noinform" "--non-interactive"
                                      "--no-sysinit" "--no-userinit"
                                      "--load" (uiop:native-namestring script))
                                :output :string :error-output :string :ignore-error-status t)
            (declare (ignore out))
            (ok (and (eql 0 code) (probe-file exe))
                (format nil "the child saved an executable (exit ~a):~%~a" code
                        (subseq err (max 0 (- (length err) 2000)))))
            (when (probe-file exe)
              (multiple-value-bind (run run-err)
                  (uiop:run-program (list (uiop:native-namestring exe))
                                    :output :string :error-output :string
                                    :ignore-error-status t)
                (ok (equal "ok" (string-trim '(#\Space #\Tab #\Return #\Newline) run))
                    (format nil "the saved image makes SSL objects: ~a~a" run run-err)))))
        (uiop:delete-file-if-exists exe)))))
