#!/usr/bin/env bash
# Clean linux/amd64 smoke of a published cl-stack-ssl, installed from GHCR by
# cl-repo inside the cl-repository ci-base image (Ubuntu 24.04, ros + SBCL +
# client). The image has the distro libssl3 (OpenSSL 3.0.x) and no
# libssl-dev: loading cl-stack-ssl must bind the overlay's OpenSSL by itself,
# with no LD_LIBRARY_PATH, and a TLS request must work.
#
#   scripts/smoke-clean-container.sh            # the .asd :version
#   scripts/smoke-clean-container.sh 3.5.9.3    # a published version
#
# Needs Docker. On an arm64 host the amd64 image runs under emulation.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(sed -n 's/^ *:version "\(.*\)".*/\1/p' "$ROOT/cl-stack-ssl.asd" | head -n 1)}"
# Package versions are <openssl>[.<packaging revision>].
OPENSSL_EXPECT="$(echo "$VERSION" | cut -d. -f1-3)"
IMAGE="${CI_BASE_IMAGE:-ghcr.io/egao1980/cl-repository/ci-base:latest}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A throwaway project: cl-repo installs what its .asd asks for.
cat >"$WORK/cl-stack-ssl-smoke.asd" <<EOF
(defsystem "cl-stack-ssl-smoke"
  :depends-on ((:version "cl-stack-ssl" "$VERSION") "cffi" "usocket"))
EOF

cat >"$WORK/smoke.lisp" <<'EOF'
(asdf:load-system "cl-stack-ssl-smoke")
(let ((want (uiop:getenv "CL_STACK_SSL_VERSION"))
      (got (asdf:component-version (asdf:find-system "cl-stack-ssl"))))
  (format t "~&cl-stack-ssl ~A (want ~A)~%" got want)
  (unless (equal got want)
    (error "loaded cl-stack-ssl ~A, not ~A" got want)))
(format t "~&overlay libssl: ~A~%"
        (uiop:symbol-call :cl-stack-ssl/paths :overlay-library-files))
(cffi:defcfun ("OpenSSL_version" %openssl-version) :string (type :int))
(let ((expect (uiop:getenv "OPENSSL_EXPECT"))
      (v (%openssl-version 0)))
  (format t "~&OpenSSL_version => ~S (expect ~A)~%" v expect)
  (unless (search (format nil "OpenSSL ~A" expect) v)
    (error "bound ~S, not the overlay's OpenSSL ~A" v expect)))
(let* ((sock (usocket:socket-connect "example.com" 443 :element-type '(unsigned-byte 8)))
       (ssl (cl+ssl:make-ssl-client-stream
             (usocket:socket-stream sock) :hostname "example.com"
             :external-format '(:utf-8 :eol-style :crlf))))
  (unwind-protect
       (progn
         (format ssl "GET / HTTP/1.1~%Host: example.com~%Connection: close~%~%")
         (force-output ssl)
         (format t "~&~A~%" (read-line ssl)))
    (close ssl)
    (usocket:socket-close sock)))
(format t "~&SMOKE OK~%")
(uiop:quit 0)
EOF

docker run --rm --platform linux/amd64 \
  -e CL_STACK_SSL_VERSION="$VERSION" \
  -e OPENSSL_EXPECT="$OPENSSL_EXPECT" \
  -v "$WORK:/smoke" -w /smoke \
  "$IMAGE" \
  bash -lc 'set -euo pipefail
    set -a; . /opt/cl-ci/image.env; set +a   # CL_REPOSITORY_DEST for the client
    if dpkg -l libssl-dev 2>/dev/null | grep -q ^ii; then echo FAIL:libssl-dev; exit 1; fi
    ros +Q -- "${CL_REPOSITORY_CLIENT_DIR%/}/roswell/cl-repo.ros" \
      ros -l smoke.lisp -q'
