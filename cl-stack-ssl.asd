(defsystem "cl-stack-ssl"
  :version "3.4.1"
  :description "OpenSSL native overlays for cl-stack; depends on stock cl+ssl"
  :author "egao1980"
  :license "MIT"
  :depends-on ("cl+ssl")
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "setup"))
  :properties
  (:cl-repo
   (:cffi-libraries ("libssl" "libcrypto")
    :provides ("cl-stack-ssl")
    :overlays
    ((:platform (:os "linux" :arch "amd64")
      :layers ((:role "native-library"
                :files (("lib/linux-amd64/libssl.so" . "libssl.so")
                        ("lib/linux-amd64/libcrypto.so" . "libcrypto.so")))))
     (:platform (:os "linux" :arch "arm64")
      :layers ((:role "native-library"
                :files (("lib/linux-arm64/libssl.so" . "libssl.so")
                        ("lib/linux-arm64/libcrypto.so" . "libcrypto.so")))))
     (:platform (:os "darwin" :arch "arm64")
      :layers ((:role "native-library"
                :files (("lib/darwin-arm64/libssl.dylib" . "libssl.dylib")
                        ("lib/darwin-arm64/libcrypto.dylib" . "libcrypto.dylib")))))
     (:platform (:os "windows" :arch "amd64")
      :layers ((:role "native-library"
                :files (("lib/windows-amd64/libssl-3-x64.dll" . "libssl-3-x64.dll")
                        ("lib/windows-amd64/libcrypto-3-x64.dll" . "libcrypto-3-x64.dll")))))))))
