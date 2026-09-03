import 'package:c2pa_viewer/src/services/ai_metadata_service.dart';
import 'package:c2pa_viewer/src/services/c2pa_platform_adapter.dart';
import 'package:c2pa_viewer/src/services/c2pa_test_sign_service.dart';
import 'package:c2pa_viewer/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

class _NativePlatformAdapter implements C2paPlatformAdapter {
  _NativePlatformAdapter(this.manifest);

  final String? manifest;
  String? receivedSourcePath;
  String? receivedOutputDirectory;
  ({String sourcePath, String outputPath, C2paWriteMode mode})? writeRequest;

  @override
  bool get usesNativeSdk => true;

  @override
  Future<String?> readManifestWithResources(
    String sourcePath,
    String outputDirectory,
  ) async {
    receivedSourcePath = sourcePath;
    receivedOutputDirectory = outputDirectory;
    return manifest;
  }

  @override
  Future<void> writeWithNativeSdk({
    required String sourcePath,
    required String outputPath,
    required C2paWriteMode mode,
  }) async {
    writeRequest = (sourcePath: sourcePath, outputPath: outputPath, mode: mode);
  }
}

void main() {
  test('uses the platform adapter for native manifest reads', () async {
    final adapter = _NativePlatformAdapter(null);
    final metadata = await AiMetadataService(
      platformAdapter: adapter,
    ).probeC2pa('/media/source.jpg');

    expect(adapter.receivedSourcePath, '/media/source.jpg');
    expect(adapter.receivedOutputDirectory, isNotEmpty);
    expect(metadata.hasC2pa, isFalse);
    AiMetadataService.cleanupExtractedResources();
  });

  test('uses the platform adapter for native writes', () async {
    final adapter = _NativePlatformAdapter(null);
    final clip = VideoClipInfo(
      path: '/media/source.jpg',
      name: 'source.jpg',
      duration: Duration.zero,
      width: 100,
      height: 100,
      hasAudio: false,
      mediaKind: MediaKind.photo,
    );

    await C2paTestSignService(
      platformAdapter: adapter,
    ).write(clip, '/media/output.jpg', C2paWriteMode.replace);

    expect(adapter.writeRequest?.sourcePath, clip.path);
    expect(adapter.writeRequest?.outputPath, '/media/output.jpg');
    expect(adapter.writeRequest?.mode, C2paWriteMode.replace);
  });
}
