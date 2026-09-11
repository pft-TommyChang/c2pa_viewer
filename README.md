<div style="text-align: center;">
  <img src="assets_app_icon_128.png" width="128" height="128" alt="Perfect C2PA app icon">
</div>

# Perfect C2PA

Perfect C2PA is a focused Android, iOS, macOS, and Windows viewer for inspecting C2PA Content
Credentials. It shows credential status, signer and manifest information,
provenance history, validation checks, and raw manifest JSON.

## Features

- Open supported photos and videos from the system file picker or by dragging
  them into the app.
- Distinguish trusted, legacy-trusted, unverified, invalid, and unsigned media.
- Browse manifest ingredients and provenance history.
- Inspect validation results and copy the complete C2PA JSON.
- Refresh the official C2PA trust list in the background.
- Open signed media directly from Perfect Collage.

## Development

Run the iOS app (iOS 16 or newer):

```bash
flutter run -d ios
```

Run the Android app (Android API 28 or newer):

```bash
flutter run -d android
```

Android release packages must be signed with a release keystore. Copy
`android/key.properties.example` to `android/key.properties` and fill in the
values, or provide the equivalent `ANDROID_*` environment variables in CI.
The keystore and properties file are intentionally ignored by Git.

The iOS build uses the native
[`c2pa-swift`](https://github.com/contentauth/c2pa-swift) package. On iOS, open
a supported photo or video with the folder button. Signed JPEG, PNG, WebP,
TIFF, HEIC, MP4, and MOV output is saved directly to the iOS Photos library.

The Android build uses the native
[`c2pa-android`](https://github.com/contentauth/c2pa-android) SDK. Its C2PA
signing key is generated and kept in the Android Keystore per installation;
the private key is not exported to Flutter. Signed media is saved to the
device media library on Android 10+. The locally generated certificate is
intended for device-local provenance and is not a public C2PA-trusted signer;
production trust requires enrolling the Keystore public key with a C2PA CA.
Android Remove C2PA uses the same behavior as iOS: images are re-encoded
without metadata, while MP4, MOV, and HEIC C2PA boxes are removed in place.

Start the viewer and drag a media file into it:

```bash
flutter run -d macos
```

On Windows, use:

```powershell
flutter run -d windows
```

Or pass a development file path directly when sandbox access permits it:

```bash
flutter run -d macos -a /absolute/path/to/media.png
```

The macOS build embeds `c2patool`. Set `C2PATOOL_PATH` to reuse an existing
binary during development:

```bash
C2PATOOL_PATH=/opt/homebrew/bin/c2patool flutter build macos --debug
```

## Verification

```bash
flutter analyze
flutter test
```

## Release build

```bash
./scripts/build_release_artifacts.sh
```

The generated DMG and SHA-256 file are written to `dist/`.

Build a signed Android App Bundle:

```bash
./scripts/build_android_release.sh
```

The signed AAB is written to `dist/`.

Create the Windows x64 ZIP bundle from a Windows development machine:

```powershell
.\scripts\build_windows_release.ps1
```

The script embeds `c2patool.exe` and the C2PA trust lists, then writes the ZIP
bundle and SHA-256 file to `dist/`.

## Perfect Collage integration

Perfect Collage locates this app by bundle identifier
`com.tommychang.perfectc2pa` and opens the selected media through macOS Launch
Services. Install `Perfect C2PA.app` in Applications before using its Content
Credentials buttons.
