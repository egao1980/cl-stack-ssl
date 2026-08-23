(in-package #:cl-stack-ssl)

;;; Overlay OpenSSL is built with --prefix=$BUILD/prefix, so
;;; SSL_CTX_set_default_verify_paths looks in a directory that does not
;;; exist on the consumer machine. Honor SSL_CERT_FILE / SSL_CERT_DIR when
;;; set; otherwise load the OS trust store (PEM bundle / hashed dir,
;;; macOS Keychain, Windows ROOT + org.openssl.winstore:).

(defvar *auto-system-cert-store* t
  "When true, ASDF load installs the OS trust store on cl+ssl's global SSL_CTX.
   Set CL_STACK_SSL_NO_SYSTEM_CERTS=1 to skip the load-time hook.")

(defvar *system-cert-store* nil
  "Descriptors last applied by ENSURE-SYSTEM-CERT-STORE, or NIL.")

(defvar *staged-ssl-cert-file* nil
  "SSL_CERT_FILE path we staged (not a user override).")

(defvar *staged-ssl-cert-dir* nil
  "SSL_CERT_DIR path we staged (not a user override).")

(define-condition system-cert-store-error (error)
  ((message :initarg :message :reader system-cert-store-error-message))
  (:report (lambda (c stream)
             (format stream "cl-stack-ssl system cert store: ~A"
                     (system-cert-store-error-message c)))))

(defparameter *unix-ca-files*
  '("/etc/ssl/certs/ca-certificates.crt"
    "/etc/pki/tls/certs/ca-bundle.crt"
    "/etc/ssl/ca-bundle.pem"
    "/etc/pki/tls/cacert.pem"
    "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem"
    "/etc/ssl/cert.pem"
    "/opt/homebrew/etc/openssl@3/cert.pem"
    "/usr/local/etc/openssl@3/cert.pem"
    "/opt/homebrew/etc/openssl@1.1/cert.pem"
    "/usr/local/etc/openssl@1.1/cert.pem"))

(defparameter *unix-ca-dirs*
  '("/etc/ssl/certs"
    "/etc/pki/tls/certs"
    "/system/etc/security/cacerts"))

(defun %env (name)
  (let ((value (uiop:getenv name)))
    (when (and value (plusp (length value)))
      value)))

(defun %parse-path (path)
  (cond
    ((pathnamep path) path)
    ((and (stringp path) (plusp (length path)))
     ;; Env vars are OS-native (C:\... on Windows). PARSE-NATIVE-NAMESTRING
     ;; keeps the drive; PATHNAME + ENSURE-PATHNAME :DEFAULTS can yield D:C:\...
     (or (ignore-errors (uiop:parse-native-namestring path))
         (pathname path)))
    (t (pathname path))))

(defun %native-path (path)
  (let ((p (%parse-path path)))
    (uiop:native-namestring
     (if (uiop:absolute-pathname-p p)
         p
         (merge-pathnames p)))))

(defun %existing-file (path)
  (when path
    (let ((p (%parse-path path)))
      (when (uiop:file-exists-p p)
        (%native-path p)))))

(defun %existing-dir (path)
  (when path
    (let ((p (%parse-path path)))
      (when (uiop:directory-exists-p p)
        (%native-path (uiop:ensure-directory-pathname p))))))

(defun %split-path-list (value)
  (when (and value (plusp (length value)))
    (uiop:split-string value :separator
                       #+(or win32 windows) ";"
                       #-(or win32 windows) ":")))

(defun %pem-cert-count (path)
  (with-open-file (in path :direction :input :if-does-not-exist nil)
    (unless in
      (return-from %pem-cert-count 0))
    (loop for line = (read-line in nil nil)
          while line
          count (search "BEGIN CERTIFICATE" line :test #'char-equal))))

(defun %probe-unix-files ()
  (loop for path in *unix-ca-files*
        for existing = (%existing-file path)
        when existing
          collect `(:source :file :path ,existing :count ,(%pem-cert-count existing))))

(defun %probe-unix-dirs ()
  (loop for path in *unix-ca-dirs*
        for existing = (%existing-dir path)
        when existing
          collect `(:source :dir :path ,existing)))

(defun %user-env (name staged)
  "SSL_CERT_* set by the user, ignoring values we staged ourselves."
  (let ((value (%env name)))
    (when (and value (not (and staged (string= value staged))))
      value)))

(defun %env-descriptors ()
  (append
   (let ((file (%existing-file (%user-env "SSL_CERT_FILE" *staged-ssl-cert-file*))))
     (when file
       (list `(:source :env-file :path ,file :count ,(%pem-cert-count file)))))
   (loop for dir in (%split-path-list (%user-env "SSL_CERT_DIR" *staged-ssl-cert-dir*))
         for existing = (%existing-dir dir)
         when existing
           collect `(:source :env-dir :path ,existing))))

;;; --- PEM encode ----------------------------------------------------------------

(defparameter +base64-alphabet+
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(defun %octets-to-base64 (octets)
  (let* ((len (length octets))
         (out (make-array (* 4 (ceiling len 3)) :element-type 'character
                                                :fill-pointer 0)))
    (labels ((enc (n)
               (vector-push (char +base64-alphabet+ n) out)))
      (loop for i from 0 below len by 3
            for a = (aref octets i)
            for b = (if (< (+ i 1) len) (aref octets (+ i 1)) nil)
            for c = (if (< (+ i 2) len) (aref octets (+ i 2)) nil)
            do (enc (ash a -2))
               (enc (logior (ash (logand a 3) 4) (if b (ash b -4) 0)))
               (if b
                   (enc (logior (ash (logand b 15) 2) (if c (ash c -6) 0)))
                   (vector-push #\= out))
               (if c
                   (enc (logand c 63))
                   (vector-push #\= out))))
    (coerce out 'string)))

(defun %der-to-pem (der)
  (with-output-to-string (s)
    (write-line "-----BEGIN CERTIFICATE-----" s)
    (loop with b64 = (%octets-to-base64 der)
          for i from 0 below (length b64) by 64
          do (write-line (subseq b64 i (min (length b64) (+ i 64))) s))
    (write-line "-----END CERTIFICATE-----" s)))

(defun %write-pem-bundle (ders path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
    (dolist (der ders)
      (write-string (%der-to-pem der) out)
      (terpri out)))
  path)

(defvar *exported-pem-path* nil)

(defun %exported-pem-path ()
  (or *exported-pem-path*
      (setf *exported-pem-path*
            (uiop:with-temporary-file (:pathname path :keep t
                                       :prefix "cl-stack-ssl-certs-"
                                       :type "pem")
              path))))

;;; --- macOS Keychain ------------------------------------------------------------

#+darwin
(progn
  (cffi:define-foreign-library security
    (t (:framework "Security")))
  (cffi:define-foreign-library corefoundation
    (t (:framework "CoreFoundation")))

  (defvar *darwin-security-loaded* nil)

  (defun %ensure-darwin-security ()
    (unless *darwin-security-loaded*
      (cffi:use-foreign-library corefoundation)
      (cffi:use-foreign-library security)
      (setf *darwin-security-loaded* t)))

  (cffi:defcfun ("CFRelease" %cf-release) :void (object :pointer))
  (cffi:defcfun ("CFArrayGetCount" %cf-array-get-count) :long (array :pointer))
  (cffi:defcfun ("CFArrayGetValueAtIndex" %cf-array-get-value-at-index) :pointer
    (array :pointer)
    (index :long))
  (cffi:defcfun ("CFDataGetLength" %cf-data-get-length) :long (data :pointer))
  (cffi:defcfun ("CFDataGetBytePtr" %cf-data-get-byte-ptr) :pointer (data :pointer))
  (cffi:defcfun ("SecTrustCopyAnchorCertificates" %sec-trust-copy-anchor-certificates)
      :int32
    (anchors :pointer))
  (cffi:defcfun ("SecTrustSettingsCopyCertificates" %sec-trust-settings-copy-certificates)
      :int32
    (domain :int32)
    (certs :pointer))
  (cffi:defcfun ("SecCertificateCopyData" %sec-certificate-copy-data) :pointer
    (cert :pointer))

  (defconstant +sec-trust-settings-domain-user+ 0)
  (defconstant +sec-trust-settings-domain-admin+ 1)
  (defconstant +err-sec-success+ 0)
  (defconstant +err-sec-no-trust-settings+ -25263)

  (defun %cfdata-octets (data)
    (let* ((len (%cf-data-get-length data))
           (ptr (%cf-data-get-byte-ptr data))
           (out (make-array len :element-type '(unsigned-byte 8))))
      (loop for i below len
            do (setf (aref out i) (cffi:mem-aref ptr :uint8 i)))
      out))

  (defun %sec-cert-der (cert)
    (let ((data (%sec-certificate-copy-data cert)))
      (when (or (cffi:null-pointer-p data) (not data))
        (return-from %sec-cert-der nil))
      (unwind-protect (%cfdata-octets data)
        (%cf-release data))))

  (defun %cfarray-cert-ders (array)
    (when (or (null array) (cffi:null-pointer-p array))
      (return-from %cfarray-cert-ders nil))
    (loop for i below (%cf-array-get-count array)
          for der = (%sec-cert-der (%cf-array-get-value-at-index array i))
          when der collect der))

  (defun %copy-anchor-ders ()
    (cffi:with-foreign-object (out :pointer)
      (let ((status (%sec-trust-copy-anchor-certificates out)))
        (unless (= status +err-sec-success+)
          (return-from %copy-anchor-ders nil))
        (let ((array (cffi:mem-ref out :pointer)))
          (unwind-protect (%cfarray-cert-ders array)
            (%cf-release array))))))

  (defun %copy-trust-settings-ders (domain)
    (cffi:with-foreign-object (out :pointer)
      (let ((status (%sec-trust-settings-copy-certificates domain out)))
        (cond
          ((= status +err-sec-success+)
           (let ((array (cffi:mem-ref out :pointer)))
             (unwind-protect (%cfarray-cert-ders array)
               (%cf-release array))))
          ((= status +err-sec-no-trust-settings+)
           nil)
          (t nil)))))

  (defun %export-keychain-pem ()
    (%ensure-darwin-security)
    (let* ((ders (append (%copy-anchor-ders)
                         (%copy-trust-settings-ders +sec-trust-settings-domain-admin+)
                         (%copy-trust-settings-ders +sec-trust-settings-domain-user+)))
           ;; Dedup identical DER blobs (anchors often overlap trust-settings).
           (unique (remove-duplicates ders :test #'equalp)))
      (unless unique
        (return-from %export-keychain-pem nil))
      (let ((path (%exported-pem-path)))
        (%write-pem-bundle unique path)
        `(:source :keychain
          :path ,(%native-path path)
          :count ,(length unique))))))

;;; --- Windows ROOT store --------------------------------------------------------

#+(or win32 windows)
(progn
  (cffi:define-foreign-library crypt32
    (t (:default "crypt32")))

  (defvar *crypt32-loaded* nil)

  (defun %ensure-crypt32 ()
    (unless *crypt32-loaded*
      (cffi:use-foreign-library crypt32)
      (setf *crypt32-loaded* t)))

  (cffi:defcfun ("CertOpenSystemStoreA" %cert-open-system-store-a) :pointer
    (prov :pointer)
    (subsystem :string))
  (cffi:defcfun ("CertEnumCertificatesInStore" %cert-enum-certificates-in-store)
      :pointer
    (store :pointer)
    (context :pointer))
  (cffi:defcfun ("CertCloseStore" %cert-close-store) :int
    (store :pointer)
    (flags :uint32))

  ;; CERT_CONTEXT on x64: DWORD, pad, BYTE*, DWORD, pad, CERT_INFO*, HCERTSTORE
  (defun %cert-context-der (ctx)
    (let* ((ptr (cffi:mem-ref ctx :pointer 8))
           (len (cffi:mem-ref ctx :uint32 16))
           (out (make-array len :element-type '(unsigned-byte 8))))
      (loop for i below len
            do (setf (aref out i) (cffi:mem-aref ptr :uint8 i)))
      out))

  (defun %export-windows-root-pem ()
    (%ensure-crypt32)
    (let ((store (%cert-open-system-store-a (cffi:null-pointer) "ROOT")))
      (when (cffi:null-pointer-p store)
        (return-from %export-windows-root-pem nil))
      (unwind-protect
           (let ((ders '())
                 (ctx (cffi:null-pointer)))
             (loop
               (setf ctx (%cert-enum-certificates-in-store store ctx))
               (when (cffi:null-pointer-p ctx)
                 (return))
               (push (%cert-context-der ctx) ders))
             (unless ders
               (return-from %export-windows-root-pem nil))
             (let ((path (%exported-pem-path)))
               (%write-pem-bundle (nreverse ders) path)
               `(:source :windows-root
                 :path ,(%native-path path)
                 :count ,(length ders))))
        (%cert-close-store store 0)))))

;;; --- OpenSSL store URI (Windows winstore) --------------------------------------

(defun %ssl-ctx-load-verify-store (ctx uri)
  (let ((ptr (cffi:foreign-symbol-pointer "SSL_CTX_load_verify_store")))
    (unless ptr
      (return-from %ssl-ctx-load-verify-store nil))
    (= 1 (cffi:foreign-funcall-pointer ptr () :pointer ctx :string uri :int))))

(defun %winstore-available-p ()
  (and (or (member :win32 *features*) (member :windows *features*))
       (not (null (cffi:foreign-symbol-pointer "SSL_CTX_load_verify_store")))))

;;; --- Discover / apply ----------------------------------------------------------

(defun discover-system-cert-store ()
  "Return OS trust-store descriptors (plists with :SOURCE and usually :PATH).

   :SOURCE is one of :ENV-FILE :ENV-DIR :FILE :DIR :KEYCHAIN :WINDOWS-ROOT :WINSTORE.
   SSL_CERT_FILE / SSL_CERT_DIR win when they name an existing path."
  (let ((from-env (%env-descriptors)))
    (when from-env
      (return-from discover-system-cert-store from-env)))
  (or
   #+darwin
   (ignore-errors
     (let ((keychain (%export-keychain-pem)))
       (when keychain (list keychain))))
   #+(or win32 windows)
   (let ((windows (ignore-errors (%export-windows-root-pem)))
         (winstore (when (%winstore-available-p)
                     '((:source :winstore :uri "org.openssl.winstore:")))))
     (append (when windows (list windows)) winstore))
   (let ((files (%probe-unix-files)))
     (if files
         (list (first files))
         (%probe-unix-dirs)))))

(defun %global-ssl-ctx ()
  (cl+ssl:ensure-initialized)
  (let ((sym (find-symbol "*SSL-GLOBAL-CONTEXT*" :cl+ssl)))
    (unless (and sym (boundp sym) (symbol-value sym))
      (error 'system-cert-store-error
             :message "cl+ssl global SSL_CTX is not initialized"))
    (symbol-value sym)))

(defun %resolve-ctx (context)
  (cond
    ((eq context :global) (%global-ssl-ctx))
    ((and (cffi:pointerp context) (not (cffi:null-pointer-p context))) context)
    (t (error 'system-cert-store-error
              :message (format nil "invalid SSL_CTX ~S" context)))))

(defun %apply-descriptor (ctx descriptor &key setenv)
  (let ((source (getf descriptor :source))
        (path (getf descriptor :path))
        (uri (getf descriptor :uri)))
    (ecase source
      ((:env-file :file :keychain :windows-root)
       (unless (and path (uiop:file-exists-p path))
         (error 'system-cert-store-error
                :message (format nil "CA file missing: ~A" path)))
       (when (and setenv (not (%user-env "SSL_CERT_FILE" *staged-ssl-cert-file*)))
         (setf (uiop:getenv "SSL_CERT_FILE") path
               *staged-ssl-cert-file* path))
       (cl+ssl::ssl-ctx-set-verify-location ctx path)
       descriptor)
      ((:env-dir :dir)
       (unless (and path (uiop:directory-exists-p path))
         (error 'system-cert-store-error
                :message (format nil "CA directory missing: ~A" path)))
       (when (and setenv (not (%user-env "SSL_CERT_DIR" *staged-ssl-cert-dir*)))
         (setf (uiop:getenv "SSL_CERT_DIR") path
               *staged-ssl-cert-dir* path))
       (cl+ssl::ssl-ctx-set-verify-location ctx path)
       descriptor)
      (:winstore
       (unless (%ssl-ctx-load-verify-store ctx (or uri "org.openssl.winstore:"))
         (error 'system-cert-store-error
                :message "SSL_CTX_load_verify_store(org.openssl.winstore:) failed"))
       descriptor))))

(defun ssl-ctx-use-system-cert-store (ctx &key (descriptors (discover-system-cert-store))
                                            (errorp t)
                                            (setenv nil))
  "Load DESCRIPTORS (from DISCOVER-SYSTEM-CERT-STORE) into SSL_CTX pointer CTX.
   SETENV is off here — only ENSURE-SYSTEM-CERT-STORE stages SSL_CERT_* so
   later cl+ssl:make-context :verify-location :default keeps working."
  (unless descriptors
    (when errorp
      (error 'system-cert-store-error :message "no system CA store found"))
    (return-from ssl-ctx-use-system-cert-store nil))
  (let ((applied '()))
    (dolist (desc descriptors)
      (handler-case
          (push (%apply-descriptor ctx desc :setenv setenv) applied)
        (error (c)
          (if errorp
              (error c)
              (warn "cl-stack-ssl: skipped ~S: ~A" (getf desc :source) c)))))
    (nreverse applied)))

(defun ensure-system-cert-store (&key (context :global) (errorp t))
  "Install the OS trust store on CONTEXT (`:global` or an SSL_CTX pointer).

   Returns the applied descriptor list. Also sets SSL_CERT_FILE / SSL_CERT_DIR
   when they were unset, so cl+ssl:make-context :verify-location :default works
   on overlay OpenSSL. Idempotent."
  (let* ((descriptors (discover-system-cert-store))
         (ctx (%resolve-ctx context))
         (applied (ssl-ctx-use-system-cert-store
                   ctx :descriptors descriptors :errorp errorp :setenv t)))
    (when applied
      (setf *system-cert-store* applied))
    applied))

(defun %auto-install-system-cert-store ()
  (when (and *auto-system-cert-store*
             (not (%env "CL_STACK_SSL_NO_SYSTEM_CERTS")))
    (let ((applied (ensure-system-cert-store :errorp nil)))
      (unless applied
        (warn "cl-stack-ssl: no system CA store found; TLS verify needs SSL_CERT_FILE or SSL_CERT_DIR")))))

(eval-when (:load-toplevel :execute)
  (%auto-install-system-cert-store))
