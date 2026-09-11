import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Mobile C2PA adapter backed by the native c2pa-swift (iOS) / c2pa-android
/// (Android) SDKs via a Flutter MethodChannel.
///
/// iOS: requires c2pa-swift added via Xcode SPM ≥ 0.0.12, iOS 16+.
/// Android: uses the c2pa-android SDK through the same channel.
class MobileC2paService {
  MobileC2paService._();

  static const _channel = MethodChannel('c2pa_native');

  static bool get isSupportedPlatform => Platform.isIOS || Platform.isAndroid;

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

  /// Reads the manifest JSON and writes thumbnail resources to [outputDir]
  /// using the same directory structure as c2patool, so _resourcePathFor can resolve them.
  /// Returns the manifest JSON string, or null if the file has no C2PA data.
  static Future<String?> readManifestWithResources(
    String filePath,
    String outputDir,
  ) async {
    if (!isSupportedPlatform) return null;
    try {
      return await _channel.invokeMethod<String>('readManifestWithResources', {
        'sourcePath': filePath,
        'outputDir': outputDir,
      });
    } catch (_) {
      return null;
    }
  }

  /// Returns the raw manifest JSON string, or null if the file has no C2PA data.
  static Future<String?> readManifestJson(String filePath) async {
    if (!isSupportedPlatform) return null;
    return _channel.invokeMethod<String>('readManifest', {'path': filePath});
  }

  // ---------------------------------------------------------------------------
  // Sign
  // ---------------------------------------------------------------------------

  /// Sign [sourcePath] → [outputPath].
  /// Supports images (jpeg, png, webp, tiff) and video (mp4, mov) on iOS and Android.
  /// Add preserves the source as a parent ingredient. Replace starts a new
  /// provenance chain. Remove strips C2PA and writes a clean output file.
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
    await _channel.invokeMethod<void>('signFile', <String, Object?>{
      'sourcePath': sourcePath,
      'outputPath': outputPath,
      'mimeType': mimeType,
      'title': 'pcc asset',
      'mode': mode.name,
    });
  }

  /// Returns a JPEG thumbnail for the media file at [filePath], or null on failure.
  /// Backed by the native thumbnailForMedia method (AVFoundation for video,
  /// CGImageSource for images).
  static Future<Uint8List?> generateThumbnail(String filePath) async {
    if (!isSupportedPlatform) return null;
    try {
      final result = await _channel.invokeMethod<Uint8List>(
        'thumbnailForMedia',
        <String, String>{'path': filePath},
      );
      return result;
    } catch (_) {
      return null;
    }
  }

  /// Removes all C2PA manifests from [sourcePath] and writes the stripped
  /// file to [outputPath]. Video/HEIC uses box stripping; images are re-encoded
  /// without metadata.
  static Future<void> removeC2pa(String sourcePath, String outputPath) async {
    if (!isSupportedPlatform) {
      throw UnsupportedError(
        'removeC2pa is only supported on mobile platforms.',
      );
    }
    await _channel.invokeMethod<void>('removeFile', {
      'sourcePath': sourcePath,
      'outputPath': outputPath,
    });
  }

  /// Saves the already-signed file to the device media library without
  /// re-encoding, so the embedded C2PA data is preserved.
  static Future<void> saveToPhotoLibrary(String filePath) async {
    if (!Platform.isIOS && !Platform.isAndroid) {
      throw UnsupportedError(
        'Saving to the media library is only supported on mobile.',
      );
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
}

enum C2paWriteModeNative { add, replace }
