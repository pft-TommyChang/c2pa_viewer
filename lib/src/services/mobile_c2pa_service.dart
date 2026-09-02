import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Mobile C2PA adapter backed by the native c2pa-swift (iOS) / c2pa-android
/// (Android) SDKs via a Flutter MethodChannel.
///
/// iOS: requires c2pa-swift added via Xcode SPM ≥ 0.0.12, iOS 16+.
/// Android: not yet implemented (no android/ directory in this project).
class MobileC2paService {
  MobileC2paService._();

  static const _channel = MethodChannel('c2pa_native');

  static const _certAsset = 'assets/c2pa/perfect_collage_cert.pem';
  static const _keyAsset = 'assets/c2pa/perfect_collage_private_pkcs8.key';

  static bool get isSupportedPlatform => Platform.isIOS;

  // ---------------------------------------------------------------------------
  // Pick original
  // ---------------------------------------------------------------------------

  /// Presents the system photo picker and returns the path of a temporary file
  /// containing the asset's original binary (HEIC/JPEG/MOV/MP4 etc.), preserving
  /// all embedded metadata including C2PA. Returns null when the user cancels.
  static Future<String?> pickOriginalMedia() async {
    if (!isSupportedPlatform) return null;
    return _channel.invokeMethod<String?>('pickOriginalMedia');
  }

  // ---------------------------------------------------------------------------
  // Read
  // ---------------------------------------------------------------------------

  /// Returns the raw manifest JSON string, or null if the file has no C2PA data.
  static Future<String?> readManifestJson(String filePath) async {
    if (!isSupportedPlatform) return null;
    return _channel.invokeMethod<String>('readManifest', {'path': filePath});
  }

  // ---------------------------------------------------------------------------
  // Sign
  // ---------------------------------------------------------------------------

  /// Sign [sourcePath] → [outputPath].
  /// Supports images (jpeg, png, webp, tiff) and video (mp4, mov) on iOS.
  /// Add preserves the source as a parent ingredient. Replace starts a new
  /// provenance chain. The native SDK does not currently expose C2PA removal.
  static Future<void> signMedia(
    String sourcePath,
    String outputPath, {
    C2paWriteModeNative mode = C2paWriteModeNative.add,
  }) async {
    if (!isSupportedPlatform) {
      throw UnsupportedError(
        'signMedia is only supported on mobile platforms.',
      );
    }

    final mimeType = _mimeType(sourcePath);
    final certPem = await _loadAssetString(_certAsset);
    final keyPem = await _loadAssetString(_keyAsset);

    await _channel.invokeMethod<void>('signFile', {
      'sourcePath': sourcePath,
      'outputPath': outputPath,
      'mimeType': mimeType,
      'certPem': certPem,
      'keyPem': keyPem,
      'title': p.basename(outputPath),
      'mode': mode.name,
    });
  }

  /// Removes all C2PA manifests from [sourcePath] and writes the stripped
  /// file to [outputPath]. Implemented via binary box stripping for video and
  /// CGImageSource re-encode (without metadata) for images.
  static Future<void> removeC2pa(
    String sourcePath,
    String outputPath,
  ) async {
    if (!isSupportedPlatform) {
      throw UnsupportedError('removeC2pa is only supported on mobile platforms.');
    }
    final mimeType = _mimeType(sourcePath);
    await _channel.invokeMethod<void>('removeFile', {
      'sourcePath': sourcePath,
      'outputPath': outputPath,
      'mimeType': mimeType,
    });
  }

  /// Saves the already-signed file to the iOS Photos library by file URL so
  /// the embedded C2PA data is not lost through image re-encoding.
  static Future<void> saveToPhotoLibrary(String filePath) async {
    if (!Platform.isIOS) {
      throw UnsupportedError('Saving to Photos is only supported on iOS.');
    }
    await _channel.invokeMethod<void>('saveToPhotoLibrary', {'path': filePath});
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static String _mimeType(String path) {
    return switch (p.extension(path).toLowerCase()) {
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.png' => 'image/png',
      '.webp' => 'image/webp',
      '.tif' || '.tiff' => 'image/tiff',
      '.heic' => 'image/heic',
      '.mp4' => 'video/mp4',
      '.mov' => 'video/quicktime',
      final ext => throw UnsupportedError(
        'c2pa_native cannot sign ${ext.isEmpty ? 'this file' : ext} on mobile.',
      ),
    };
  }

  static Future<String> _loadAssetString(String assetPath) async {
    final bytes = await rootBundle.load(assetPath);
    return String.fromCharCodes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
  }
}

enum C2paWriteModeNative { add, replace }
