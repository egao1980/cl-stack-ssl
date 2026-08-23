(in-package #:cl-stack-ssl/tests)

(defun %env (name)
  (let ((value (uiop:getenv name)))
    (when (and value (plusp (length value)))
      value)))

(defun %call-with-env (name value fn)
  (let ((old (%env name)))
    (unwind-protect
         (progn
           (if value
               (setf (uiop:getenv name) value)
               (setf (uiop:getenv name) ""))
           (funcall fn))
      (if old
          (setf (uiop:getenv name) old)
          (setf (uiop:getenv name) "")))))

(defun %source-of (descriptors source)
  (find source descriptors :key (lambda (d) (getf d :source))))

(deftest discover-finds-os-store
  (let ((found (discover-system-cert-store)))
    (ok found "OS or env trust store is visible")
    (ok (every #'consp found))
    (ok (every (lambda (d) (getf d :source)) found))))

(deftest ensure-installs-global-store
  (let ((applied (ensure-system-cert-store :errorp t)))
    (ok applied)
    (ok *system-cert-store*)
    (ok (equal (getf (first applied) :source)
               (getf (first *system-cert-store*) :source)))))

(deftest env-file-override
  (uiop:with-temporary-file (:pathname path :keep t :type "pem")
    (with-open-file (out path :direction :output :if-exists :supersede)
      (write-line "-----BEGIN CERTIFICATE-----" out)
      (write-line "-----END CERTIFICATE-----" out))
    (%call-with-env
     "SSL_CERT_FILE" (uiop:native-namestring path)
     (lambda ()
       (let ((found (discover-system-cert-store)))
         (ok (%source-of found :env-file))
         (ok (equal (getf (%source-of found :env-file) :path)
                    (uiop:native-namestring path))))))))

(deftest ensure-ssl-still-reports-version
  (multiple-value-bind (ok version) (ensure-ssl)
    (ok ok)
    (ok (string= version +openssl-version+))))

(deftest discover-keeps-platform-source
  "Staging SSL_CERT_FILE for overlay OpenSSL must not look like a user override."
  (let ((found (discover-system-cert-store)))
    (ng (%source-of found :env-file))))

(deftest pem-cert-count-positive
  (let ((desc (or (%source-of *system-cert-store* :keychain)
                  (%source-of *system-cert-store* :windows-root)
                  (%source-of *system-cert-store* :file)
                  (%source-of *system-cert-store* :env-file))))
    (if (and desc (getf desc :count))
        (ok (plusp (getf desc :count)) "exported/file store has at least one CA")
        (skip "store has no :count (dir or winstore-only)"))))

(deftest live-verify-example-com
  (if (not (equal "1" (uiop:getenv "CL_STACK_SSL_LIVE")))
      (skip "set CL_STACK_SSL_LIVE=1 to hit example.com with :verify t")
      (let* ((sock (usocket:socket-connect "example.com" 443
                                           :element-type '(unsigned-byte 8)
                                           :timeout 15))
             (ssl (cl+ssl:make-ssl-client-stream
                   (usocket:socket-stream sock)
                   :hostname "example.com"
                   :verify t
                   :external-format '(:utf-8 :eol-style :crlf))))
        (unwind-protect
             (progn
               (format ssl "GET / HTTP/1.1~%Host: example.com~%Connection: close~%~%")
               (force-output ssl)
               (ok (search "HTTP/" (read-line ssl) :test #'char-equal)))
          (ignore-errors (close ssl))
          (ignore-errors (usocket:socket-close sock))))))
