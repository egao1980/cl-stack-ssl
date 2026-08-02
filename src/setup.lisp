(in-package #:cl-stack-ssl)

(defconstant +openssl-version+ "3.4.1"
  "OpenSSL release this package version tracks (must match ASDF :version / OCI tag).")

(defun ensure-ssl ()
  "Confirm cl+ssl is loaded. Call after cl-repository install so overlay
   native/ is already on cffi:*foreign-library-directories*."
  (unless (find-package :cl+ssl)
    (error "cl+ssl is not loaded; load system cl-stack-ssl via ASDF/cl-repository"))
  (values t +openssl-version+))
