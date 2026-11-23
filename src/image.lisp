(in-package #:cl-stack-ssl)

;;; Saved images (uiop:dump-image, sb-ext:save-lisp-and-die).
;;;
;;; Loading this system initializes cl+ssl: the load-time trust-store hook in
;;; system-certs.lisp creates cl+ssl's global SSL_CTX, its SSL_METHOD and the
;;; Lisp BIO method. They are foreign pointers of the loading process. A saved
;;; image keeps them, cl+ssl:ssl-initialized-p is true in the new process, and
;;; the first handshake uses dead memory: a memory fault inside libssl (#23).
;;; The trust-store state (the exported PEM file, the SSL_CERT_FILE /
;;; SSL_CERT_DIR we staged) belongs to the saving process too.
;;;
;;; FORGET-SSL-STATE runs before the image is saved; RESTORE-SSL-STATE runs when
;;; it starts and installs the trust store on a new global SSL_CTX, as loading
;;; the system does. Not cl+ssl:reload: it reopens the libraries through
;;; cl+ssl's own search, which on macOS takes Homebrew's OpenSSL (4, missing
;;; functions cl+ssl calls) instead of the overlay, and the next call through
;;; the new TLS_method jumps to garbage.

(defun forget-ssl-state ()
  "Drop the foreign pointers and trust-store settings of this process: cl+ssl's
global SSL_CTX, SSL_METHOD and Lisp BIO method, the applied store, the exported
PEM file and the staged SSL_CERT_FILE / SSL_CERT_DIR. The next TLS use
initializes cl+ssl from scratch."
  (setf cl+ssl::*ssl-global-context* nil
        cl+ssl::*ssl-global-method* nil
        cl+ssl::*bio-lisp-method* nil
        *system-cert-store* nil
        *exported-pem-path* nil
        *staged-ssl-cert-file* nil
        *staged-ssl-cert-dir* nil)
  nil)

(defun restore-ssl-state ()
  "When a saved image starts: forget what the saving process left (in case no
dump hook ran), then install the OS trust store on a new global SSL_CTX unless
*AUTO-SYSTEM-CERT-STORE* is false or CL_STACK_SSL_NO_SYSTEM_CERTS is set."
  (forget-ssl-state)
  (%auto-install-system-cert-store))

;;; uiop:dump-image saves through save-lisp-and-die on SBCL, so SBCL's own
;;; hooks cover both ways to save; the UIOP hooks serve the other Lisps.
#+sbcl
(progn
  (pushnew 'forget-ssl-state sb-ext:*save-hooks*)
  (pushnew 'restore-ssl-state sb-ext:*init-hooks*))
#-sbcl
(progn
  (uiop:register-image-dump-hook 'forget-ssl-state)
  (uiop:register-image-restore-hook 'restore-ssl-state nil))
