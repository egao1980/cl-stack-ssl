#!/usr/bin/env bash
# Build shared OpenSSL (libssl + libcrypto) into lib/<os>-<arch>/.
# Usage: ./scripts/build-openssl.sh
# Env: OPENSSL_VERSION (default 3.4.1), DEST_DIR (optional override)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.4.1}"
JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

uname_s="$(uname -s)"
uname_m="$(uname -m)"
case "$uname_s" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT) os=windows ;;
  *) echo "unsupported OS: $uname_s" >&2; exit 1 ;;
esac
case "$uname_m" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo "unsupported arch: $uname_m" >&2; exit 1 ;;
esac

OUT="${DEST_DIR:-$ROOT/lib/${os}-${arch}}"
BUILD="$ROOT/build/openssl-${OPENSSL_VERSION}-${os}-${arch}"
SRC_TGZ="$ROOT/build/openssl-${OPENSSL_VERSION}.tar.gz"
SRC_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"

mkdir -p "$ROOT/build" "$OUT"
if [[ ! -f "$SRC_TGZ" ]]; then
  echo "==> download $SRC_URL"
  curl -fsSL "$SRC_URL" -o "$SRC_TGZ"
fi

rm -rf "$BUILD"
mkdir -p "$BUILD"
tar -xzf "$SRC_TGZ" -C "$BUILD" --strip-components=1

echo "==> configure OpenSSL ${OPENSSL_VERSION} -> $OUT"
cd "$BUILD"
# shared libs only; install_sw skips manpages
if [[ "$os" == "darwin" ]]; then
  ./Configure darwin64-$([[ "$arch" == "arm64" ]] && echo arm64 || echo x86_64)-cc \
    shared no-tests --prefix="$BUILD/prefix" --libdir=lib
elif [[ "$os" == "linux" ]]; then
  ./Configure "linux-$([[ "$arch" == "arm64" ]] && echo aarch64 || echo x86_64)" \
    shared no-tests --prefix="$BUILD/prefix" --libdir=lib
else
  echo "Windows: use CI windows-latest / self-hosted (MSVC) — not this script." >&2
  exit 1
fi

make -j"$JOBS"
make install_sw

echo "==> stage shared libs into $OUT"
rm -rf "$OUT"
mkdir -p "$OUT"
# Copy real shared objects + soname/compat names cl+ssl / dlopen expect.
if [[ "$os" == "linux" ]]; then
  cp -a "$BUILD/prefix/lib"/libssl.so* "$OUT/"
  cp -a "$BUILD/prefix/lib"/libcrypto.so* "$OUT/"
  # Ensure unversioned names exist for CFFI (:unix "libssl.so")
  (cd "$OUT" && ls libssl.so.* >/dev/null && ln -sfn "$(ls -1 libssl.so.* | head -1)" libssl.so)
  (cd "$OUT" && ls libcrypto.so.* >/dev/null && ln -sfn "$(ls -1 libcrypto.so.* | head -1)" libcrypto.so)
  if command -v patchelf >/dev/null; then
    for f in "$OUT"/libssl.so* "$OUT"/libcrypto.so*; do
      [[ -f "$f" && ! -L "$f" ]] || continue
      patchelf --set-rpath '$ORIGIN' "$f"
    done
  fi
elif [[ "$os" == "darwin" ]]; then
  cp -a "$BUILD/prefix/lib"/libssl*.dylib "$OUT/"
  cp -a "$BUILD/prefix/lib"/libcrypto*.dylib "$OUT/"
  (cd "$OUT" && ls libssl.*.dylib >/dev/null 2>&1 && ln -sfn "$(ls -1 libssl.*.dylib | head -1)" libssl.dylib) || true
  (cd "$OUT" && ls libcrypto.*.dylib >/dev/null 2>&1 && ln -sfn "$(ls -1 libcrypto.*.dylib | head -1)" libcrypto.dylib) || true
  # Prefer @loader_path for portable overlay loads
  if command -v install_name_tool >/dev/null; then
    for f in "$OUT"/libssl*.dylib "$OUT"/libcrypto*.dylib; do
      [[ -f "$f" && ! -L "$f" ]] || continue
      install_name_tool -id "@loader_path/$(basename "$f")" "$f" 2>/dev/null || true
    done
    # Point libssl at sibling libcrypto if needed
    if [[ -f "$OUT/libssl.dylib" || -L "$OUT/libssl.dylib" ]]; then
      real_ssl="$(cd "$OUT" && realpath libssl.dylib 2>/dev/null || readlink libssl.dylib || true)"
      real_crypto="$(cd "$OUT" && realpath libcrypto.dylib 2>/dev/null || readlink libcrypto.dylib || true)"
      if [[ -n "${real_ssl:-}" && -f "$OUT/$real_ssl" && -n "${real_crypto:-}" ]]; then
        install_name_tool -change \
          "$BUILD/prefix/lib/$(basename "$real_crypto")" \
          "@loader_path/$(basename "$real_crypto")" \
          "$OUT/$real_ssl" 2>/dev/null || true
      fi
    fi
  fi
fi

echo "==> staged:"
ls -la "$OUT"
echo "OK: OpenSSL ${OPENSSL_VERSION} -> ${os}/${arch}"
