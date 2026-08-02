#!/usr/bin/env bash
# Rewrite ASDF :version and +openssl-version+ to match the published OpenSSL release.
# Usage: ./scripts/sync-package-version.sh <version>
set -euo pipefail

VERSION="${1:?version required}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

sed -i 's/:version "[^"]*"/:version "'"${VERSION}"'"/' "$ROOT/cl-stack-ssl.asd"
sed -i 's/(defconstant +openssl-version+ "[^"]*"/(defconstant +openssl-version+ "'"${VERSION}"'"/' "$ROOT/src/setup.lisp"
