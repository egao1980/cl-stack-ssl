(defpackage #:cl-stack-ssl
  (:use #:cl)
  (:export #:+openssl-version+
           #:ensure-ssl
           #:*auto-system-cert-store*
           #:*system-cert-store*
           #:system-cert-store-error
           #:system-cert-store-error-message
           #:discover-system-cert-store
           #:ensure-system-cert-store
           #:ssl-ctx-use-system-cert-store))
