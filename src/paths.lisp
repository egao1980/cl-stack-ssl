(defpackage #:cl-stack-ssl/paths
  (:use #:cl)
  (:export #:overlay-library-directory
           #:overlay-library-files
           #:pin-cl+ssl-libraries))

(in-package #:cl-stack-ssl/paths)

;;; Point cl+ssl at this package's OpenSSL before cl+ssl defines its foreign
;;; libraries. Without this cl+ssl searches fixed paths first: on macOS it
;;; takes /opt/homebrew/opt/openssl/lib, which Homebrew now points at OpenSSL
;;; 4 — a release that removed functions cl+ssl still calls (ASN1_STRING_data).

(defun platform-directory-name ()
  (format nil "~A-~A"
          (cond ((uiop:os-macosx-p) "darwin") ((uiop:os-windows-p) "windows") (t "linux"))
          #+(or arm64 aarch64) "arm64" #-(or arm64 aarch64) "amd64"))

(defun candidate-names (which)
  (ecase which
    (:ssl (cond ((uiop:os-macosx-p) '("libssl.3.dylib" "libssl.dylib"))
                ((uiop:os-windows-p) '("libssl-3-x64.dll"))
                (t '("libssl.so.3" "libssl.so"))))
    (:crypto (cond ((uiop:os-macosx-p) '("libcrypto.3.dylib" "libcrypto.dylib"))
                   ((uiop:os-windows-p) '("libcrypto-3-x64.dll"))
                   (t '("libcrypto.so.3" "libcrypto.so"))))))

(defun library-file (directory which)
  (loop for name in (candidate-names which)
        for path = (merge-pathnames name directory)
        when (probe-file path) return path))

(defun overlay-library-directory ()
  "Directory holding this package's libssl and libcrypto: native/ in a
cl-repository install, lib/<os>-<arch>/ in a checkout with built libraries,
or NIL. CL_STACK_SSL_SYSTEM_OPENSSL=1 disables the overlay."
  (unless (member (uiop:getenv "CL_STACK_SSL_SYSTEM_OPENSSL") '("1" "true" "yes") :test #'equal)
    (let ((root (asdf:system-source-directory "cl-stack-ssl")))
      (find-if (lambda (dir) (and (library-file dir :ssl) (library-file dir :crypto)))
               (list (merge-pathnames "native/" root)
                     (merge-pathnames (format nil "lib/~A/" (platform-directory-name)) root))))))

(defun overlay-library-files ()
  "(values libssl libcrypto) of the overlay, or NIL."
  (let ((dir (overlay-library-directory)))
    (when dir
      (values (library-file dir :ssl) (library-file dir :crypto)))))

(defun pin-cl+ssl-libraries ()
  "Make cl+ssl load the overlay's OpenSSL. Returns the libssl path, or NIL when
there is no overlay. A warning says so when cl+ssl was loaded earlier: its
libraries are already chosen."
  (multiple-value-bind (ssl crypto) (overlay-library-files)
    (when ssl
      (if (find-package "CL+SSL")
          (warn "cl+ssl was loaded before cl-stack-ssl; it keeps the OpenSSL it found, not ~A" ssl)
          (progn
            ;; the DEFINE-LIB*-PATH macros take an unevaluated path
            (eval (list (find-symbol "DEFINE-LIBCRYPTO-PATH" "CL+SSL/CONFIG") (namestring crypto)))
            (eval (list (find-symbol "DEFINE-LIBSSL-PATH" "CL+SSL/CONFIG") (namestring ssl)))))
      ssl)))

(pin-cl+ssl-libraries)
