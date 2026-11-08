(in-package #:cl-stack-ssl)

;; defparameter: SBCL DEFCONSTANT on strings trips DEFCONSTANT-UNEQL on reload
;; (compile-time vs load-time string objects are EQUAL but not EQL).
(defparameter +openssl-version+
  (let ((parts (uiop:split-string (asdf:component-version (asdf:find-system "cl-stack-ssl"))
                                  :separator ".")))
    (format nil "~{~A~^.~}" (subseq parts 0 (min 3 (length parts)))))
  "OpenSSL release this package tracks: the first three parts of the ASDF :version and OCI tag (the fourth is the package revision).")

(defun ensure-ssl ()
  "Confirm cl+ssl is loaded and the OS trust store is installed on the
   global SSL_CTX. Overlay `native/` must win over distro libssl —
   set LD_LIBRARY_PATH (or DYLD_LIBRARY_PATH) to the install's native/ *before*
   starting the Lisp process when the image already has libssl."
  (unless (find-package :cl+ssl)
    (error "cl+ssl is not loaded; load system cl-stack-ssl via ASDF/cl-repository"))
  (ensure-system-cert-store :errorp nil)
  (values t +openssl-version+))
