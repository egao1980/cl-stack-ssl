(in-package #:cl-stack-ssl)

;; defparameter: SBCL DEFCONSTANT on strings trips DEFCONSTANT-UNEQL on reload
;; (compile-time vs load-time string objects are EQUAL but not EQL).
(defparameter +openssl-version+ "3.4.1"
  "OpenSSL release this package version tracks (must match ASDF :version / OCI tag).")

(defun ensure-ssl ()
  "Confirm cl+ssl is loaded. Overlay `native/` must win over distro libssl —
   set LD_LIBRARY_PATH (or DYLD_LIBRARY_PATH) to the install's native/ *before*
   starting the Lisp process when the image already has libssl."
  (unless (find-package :cl+ssl)
    (error "cl+ssl is not loaded; load system cl-stack-ssl via ASDF/cl-repository"))
  (values t +openssl-version+))
