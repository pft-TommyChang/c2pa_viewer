import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

import '../models.dart';
import 'ai_metadata_service.dart';
import 'mobile_c2pa_service.dart';

class MediaInspectionService {
  const MediaInspectionService({
    this.aiMetadataService = const AiMetadataService(),
  });

  static const MethodChannel _mediaProbeChannel = MethodChannel(
    'c2pa_viewer/media_probe',
  );
  static const MethodChannel _c2paNativeChannel = MethodChannel('c2pa_native');

  // Probes file metadata (EXIF/GPS/QuickTime) grouped by namespace.
  // Uses media_probe channel on macOS/Windows, c2pa_native on iOS/Android.
  static Future<Map<String, Map<String, String>>> _probeExifMetadata(
    String path,
  ) async {
    try {
      final Map<Object?, Object?>? raw;
      if (Platform.isIOS || Platform.isAndroid) {
        raw = await _c2paNativeChannel.invokeMapMethod<Object?, Object?>(
          'probeExifMetadata',
          <String, Object?>{'path': path},
        );
      } else {
        raw = await _mediaProbeChannel.invokeMapMethod<Object?, Object?>(
          'probeExifMetadata',
          <String, Object?>{'path': path},
        );
      }
      if (raw == null) return const <String, Map<String, String>>{};
      final result = <String, Map<String, String>>{};
      for (final entry in raw.entries) {
        final groupName = entry.key?.toString() ?? '';
        final groupMap = entry.value;
        if (groupMap is Map) {
          result[groupName] = Map<String, String>.fromEntries(
            groupMap.entries.map(
              (e) => MapEntry(e.key.toString(), e.value.toString()),
            ),
          );
        }
      }
      return result;
    } catch (_) {
      return const <String, Map<String, String>>{};
    }
  }

  final AiMetadataService aiMetadataService;

  static Future<Uint8List?> thumbnail(String path) async {
    // On mobile, the media_probe channel has no iOS/Android implementation —
    // delegate to the c2pa_native channel instead.
    if (Platform.isIOS || Platform.isAndroid) {
      return MobileC2paService.generateThumbnail(path);
    }
    try {
      final result = await _mediaProbeChannel.invokeMethod<Uint8List>(
        'thumbnailForMedia',
        <String, Object?>{'path': path},
      );
      return result;
    } catch (_) {
      return null;
    }
  }

  static Future<void> removeC2pa(String sourcePath, String outputPath) async {
    await _mediaProbeChannel.invokeMethod<void>(
      'removeC2paFromMedia',
      <String, Object?>{'path': sourcePath, 'outputPath': outputPath},
    );
  }

  static Future<void> withSecurityScopedAccess(
    String path,
    Future<void> Function() action,
  ) async {
    var hasSecurityScopedAccess = false;
    try {
      hasSecurityScopedAccess =
          await _mediaProbeChannel.invokeMethod<bool>(
            'beginAccessingMedia',
            <String, Object?>{'path': path},
          ) ??
          false;
    } on MissingPluginException {
      // Tests and non-native runners can operate without security scoping.
    }
    try {
      await action();
    } finally {
      if (hasSecurityScopedAccess) {
        await _mediaProbeChannel.invokeMethod<void>(
          'endAccessingMedia',
          <String, Object?>{'path': path},
        );
      }
    }
  }

  Future<VideoClipInfo> inspect(String path) async {
    if (Platform.isIOS || Platform.isAndroid) {
      return _inspectMobile(path);
    }
    var hasSecurityScopedAccess = false;
    try {
      hasSecurityScopedAccess =
          await _mediaProbeChannel.invokeMethod<bool>(
            'beginAccessingMedia',
            <String, Object?>{'path': path},
          ) ??
          false;
      final results = await Future.wait<Object?>(<Future<Object?>>[
        _mediaProbeChannel.invokeMapMethod<String, Object?>(
          'probeMedia',
          <String, Object?>{'path': path},
        ),
        aiMetadataService.probe(path),
        _probeExifMetadata(path),
      ]);
      final media = results[0] as Map<String, Object?>?;
      if (media == null) {
        throw PlatformException(
          code: 'probe-failed',
          message: 'The media file could not be inspected.',
        );
      }
      return VideoClipInfo(
        path: path,
        name: p.basename(path),
        duration: Duration(
          milliseconds: (((media['durationSeconds'] as num?) ?? 0) * 1000)
              .round(),
        ),
        width: (media['width'] as num?)?.round() ?? 0,
        height: (media['height'] as num?)?.round() ?? 0,
        hasAudio: media['hasAudio'] == true,
        mediaKind: media['isPhoto'] == true ? MediaKind.photo : MediaKind.video,
        aiMetadata: results[1] as AiMediaMetadata,
        exifGroups: results[2] as Map<String, Map<String, String>>,
      );
    } finally {
      if (hasSecurityScopedAccess) {
        await _mediaProbeChannel.invokeMethod<void>(
          'endAccessingMedia',
          <String, Object?>{'path': path},
        );
      }
    }
  }

  Future<VideoClipInfo> _inspectMobile(String path) async {
    final extension = p.extension(path).toLowerCase();
    final isPhoto = const <String>{
      '.jpg',
      '.jpeg',
      '.png',
      '.webp',
      '.heic',
      '.heif',
    }.contains(extension);
    var width = 0;
    var height = 0;
    var duration = Duration.zero;

    if (isPhoto) {
      final codec = await ui.instantiateImageCodec(
        await File(path).readAsBytes(),
      );
      try {
        final frame = await codec.getNextFrame();
        width = frame.image.width;
        height = frame.image.height;
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
    } else {
      final controller = VideoPlayerController.file(File(path));
      try {
        await controller.initialize();
        width = controller.value.size.width.round();
        height = controller.value.size.height.round();
        duration = controller.value.duration;
      } finally {
        await controller.dispose();
      }
    }

    final exifGroups = await _probeExifMetadata(path);
    return VideoClipInfo(
      path: path,
      name: p.basename(path),
      duration: duration,
      width: width,
      height: height,
      hasAudio: !isPhoto,
      mediaKind: isPhoto ? MediaKind.photo : MediaKind.video,
      aiMetadata: await aiMetadataService.probe(path),
      exifGroups: exifGroups,
    );
  }
}
