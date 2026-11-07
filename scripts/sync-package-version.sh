#!/usr/bin/env bash
# Rewrite ASDF :version and +openssl-version+ for a published package version.
# Usage: ./scripts/sync-package-version.sh <version>
# The OpenSSL release is the first three components: 3.5.9.1 packages OpenSSL 3.5.9.
set -euo pipefail

VERSION="${1:?version required}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

sed -i 's/:version "[^"]*"/:version "'"${VERSION}"'"/' "$ROOT/cl-stack-ssl.asd"
OPENSSL="$(echo "$VERSION" | cut -d. -f1-3)"
sed -i 's/(defparameter +openssl-version+ "[^"]*"/(defparameter +openssl-version+ "'"${OPENSSL}"'"/' "$ROOT/src/setup.lisp"
