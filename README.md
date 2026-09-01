# Perfect C2PA

Perfect C2PA is a focused macOS viewer for inspecting C2PA Content
Credentials. It shows credential status, signer and manifest information,
provenance history, validation checks, and raw manifest JSON.

## Features

- Open supported photos and videos from Finder or by dragging them into the app.
- Distinguish trusted, legacy-trusted, unverified, invalid, and unsigned media.
- Browse manifest ingredients and provenance history.
- Inspect validation results and copy the complete C2PA JSON.
- Refresh the official C2PA trust list in the background.
- Open signed media directly from Perfect Collage.

## Development

Start the viewer and drag a media file into it:

```bash
flutter run -d macos
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

## Perfect Collage integration

Perfect Collage locates this app by bundle identifier
`com.tommychang.perfectc2pa` and opens the selected media through macOS Launch
Services. Install `Perfect C2PA.app` in Applications before using its Content
Credentials buttons.
