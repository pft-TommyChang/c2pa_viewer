# Minimal C2PA mobile build

The mobile SDK releases include optional HTTP, PDF, thumbnail, and OpenSSL
features. This project only needs local file I/O plus signing and validation.

The script defaults to `c2pa-c-ffi` 0.85.2 because it matches the C ABI used
by the small Swift bridge vendored in `ios/Runner/C2PALocal.swift`. Do not
change `C2PA_REF` to 0.90.0 without also updating that bridge: that release removes
`c2pa_read_file`, `c2pa_read_ingredient_file`, and `c2pa_sign_file`, producing
an iOS linker failure.

Build a local minimal C FFI with:

```sh
scripts/build_minimal_c2pa.sh
```

The script produces:

- `.c2pa-minimal-build/ios/C2PAC.xcframework`
- `.c2pa-minimal-build/android-archives/c2pa-minimal-*.zip`

The Android archives can be supplied to the upstream `c2pa-android` build with
`-Pc2paArchiveDir=...`. For iOS, copy the generated XCFramework into
`ios/Frameworks/C2PAC.xcframework`; the Runner target links it directly.

The generated iOS static archives are roughly 312 MB combined. Keep them out
of ordinary Git history; use Git LFS or a CI/release artifact. This repository
tracks the iOS framework in Git LFS and does not use the `c2pa-swift` binary
package, so Xcode no longer downloads its `C2PAC.xcframework` artifact.

The local certificate helper uses Apple's `swift-crypto`, `swift-asn1`, and
`swift-certificates` source packages. They are resolved once by Xcode to create
a self-signed certificate for each device; they are not C2PA binary artifacts.

The generated library must be tested against the app's supported formats and
signing flows before replacing the published SDKs.
