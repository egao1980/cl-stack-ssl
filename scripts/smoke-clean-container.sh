#!/usr/bin/env bash
# Clean ubuntu:24.04 linux/amd64 smoke against GHCR cl-stack-ssl.
# Fast path: reuse /tmp/cl-stack-ssl-smoke-cache/{ql,pkg} across runs.
set -euo pipefail

VERSION="${1:-3.4.1}"
IMAGE="ghcr.io/egao1980/cl-systems/cl-stack-ssl:${VERSION}"
CACHE="${CACHE:-/tmp/cl-stack-ssl-smoke-cache}"
PKG="$CACHE/pkg/cl-stack-ssl-${VERSION}"
QL="$CACHE/quicklisp"

mkdir -p "$CACHE/pull" "$CACHE/pkg"
if [[ ! -f "$PKG/native/libssl.so" ]]; then
  command -v oras >/dev/null || { echo "need oras" >&2; exit 1; }
  rm -rf "$CACHE/pull"/* "$CACHE/pkg"/*
  oras pull --platform linux/amd64 "$IMAGE" -o "$CACHE/pull/"
  for f in "$CACHE/pull"/*.tar.gz; do tar -xzf "$f" -C "$CACHE/pkg/"; done
fi

SMOKE_LISP="$CACHE/smoke.lisp"
cat >"$SMOKE_LISP" <<'EOF'
(require :asdf) (require :uiop)
(defvar *pkg* (uiop:getenv "CL_STACK_SSL_ROOT"))
(asdf:initialize-source-registry
 `(:source-registry (:directory ,(uiop:ensure-directory-pathname *pkg*))
                    :inherit-configuration))
(ql:quickload '("cffi" "cl-stack-ssl" "usocket") :silent t)
(cffi:defcfun ("OpenSSL_version" %openssl-version) :string (type :int))
(let* ((expect (or (uiop:getenv "OPENSSL_EXPECT") "3.4.1"))
       (v (%openssl-version 0)))
  (format t "~&OpenSSL_version => ~S (expect ~A)~%" v expect)
  (unless (search (format nil "OpenSSL ~A" expect) v)
    (error "wrong OpenSSL: ~S" v)))
(let* ((connect (find-symbol "SOCKET-CONNECT" :usocket))
       (stream (find-symbol "SOCKET-STREAM" :usocket))
       (close* (find-symbol "SOCKET-CLOSE" :usocket))
       (make-ssl (find-symbol "MAKE-SSL-CLIENT-STREAM" :cl+ssl))
       (sock (funcall connect "example.com" 443 :element-type '(unsigned-byte 8)))
       (ssl (funcall make-ssl (funcall stream sock) :hostname "example.com"
                     :verify nil :external-format '(:utf-8 :eol-style :crlf))))
  (unwind-protect
       (progn
         (format ssl "GET / HTTP/1.1~%Host: example.com~%Connection: close~%~%")
         (force-output ssl)
         (format t "~&~A~%" (read-line ssl)))
    (ignore-errors (close ssl))
    (ignore-errors (funcall close* sock))))
(format t "~&SMOKE OK~%")
(uiop:quit 0)
EOF

# Seed Quicklisp once into a volume-backed cache dir on the host.
if [[ ! -f "$QL/setup.lisp" ]]; then
  docker run --rm --platform linux/amd64 \
    -e DEBIAN_FRONTEND=noninteractive \
    -v "$QL:/ql" \
    ubuntu:24.04 \
    bash -c 'apt-get update -qq && apt-get install -y -qq ca-certificates curl sbcl >/dev/null \
      && curl -fsSL -o /tmp/ql.lisp https://beta.quicklisp.org/quicklisp.lisp \
      && sbcl --noinform --non-interactive --load /tmp/ql.lisp \
           --eval "(quicklisp-quickstart:install :path #p\"/ql/\")" >/dev/null'
fi

docker run --rm --platform linux/amd64 \
  -e DEBIAN_FRONTEND=noninteractive \
  -e CL_STACK_SSL_ROOT=/opt/cl-stack-ssl \
  -e LD_LIBRARY_PATH=/opt/cl-stack-ssl/native \
  -v "$PKG:/opt/cl-stack-ssl:ro" \
  -v "$QL:/ql:ro" \
  -v "$SMOKE_LISP:/opt/smoke.lisp:ro" \
  ubuntu:24.04 \
  bash -c 'apt-get update -qq && apt-get install -y -qq ca-certificates sbcl >/dev/null \
    && if dpkg -l libssl-dev 2>/dev/null | grep -q ^ii; then echo FAIL:libssl-dev; exit 1; fi \
    && sbcl --noinform --non-interactive --load /ql/setup.lisp --load /opt/smoke.lisp'
