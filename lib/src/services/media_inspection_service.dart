import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models.dart';
import 'ai_metadata_service.dart';

class MediaInspectionService {
  const MediaInspectionService({
    this.aiMetadataService = const AiMetadataService(),
  });

  static const MethodChannel _mediaProbeChannel = MethodChannel(
    'c2pa_viewer/media_probe',
  );

  final AiMetadataService aiMetadataService;

  static Future<Uint8List?> thumbnail(String path) async {
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

  Future<VideoClipInfo> inspect(String path) async {
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
}
