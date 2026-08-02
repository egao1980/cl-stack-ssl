# cl-stack-ssl

MIT. Ships **OpenSSL** shared libraries (`libssl` + `libcrypto`, same build) as
[cl-repository](https://github.com/egao1980/cl-repository) platform overlays, and
depends on stock [cl+ssl](https://github.com/cl-plus-ssl/cl-plus-ssl) for the Lisp API.

**Not** a fork of cl+ssl. Discovery/install is the product; the API stays upstream.

| | |
|--|--|
| ASDF | `cl-stack-ssl` |
| GHCR | `ghcr.io/egao1980/cl-systems/cl-stack-ssl:<openssl-ver>` |
| Tracks | [egao1980/cl-stack#12](https://github.com/egao1980/cl-stack/issues/12) |

## Consumer

```lisp
;; After cl-repository install (init pushes native/ onto CFFI search path):
(asdf:load-system "cl-stack-ssl")   ; pulls in cl+ssl
(cl-stack-ssl:ensure-ssl)
```

Clean container: Roswell/SBCL, **no** OpenSSL/dev packages — install from GHCR, then load.

## Build natives locally

```bash
./scripts/build-openssl.sh          # OPENSSL_VERSION=3.4.1 by default
# → lib/<os>-<arch>/libssl.* libcrypto.* (+ versioned sonames / Windows DLLs)
```

## Publish

Tag `v<openssl-ver>` or `workflow_dispatch` → `.github/workflows/publish-oci.yml`
(matrix: `linux/amd64`, `linux/arm64`, `darwin/arm64`; `windows/amd64` when a
self-hosted or `windows-latest` build is wired).

Policy: [cl-stack overlays](https://github.com/egao1980/cl-stack/blob/main/docs/overlays.md),
[overlay CI](https://github.com/egao1980/cl-stack/blob/main/docs/overlay-ci.md).

## License

- This repo: MIT (`LICENSE`)
- Bundled OpenSSL binaries: [Apache-2.0](https://www.openssl.org/source/license.html) — see `NOTICE`
