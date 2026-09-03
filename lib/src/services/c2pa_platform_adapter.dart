import 'c2pa_write_models.dart';
import 'mobile_c2pa_service.dart';

/// Platform boundary for C2PA SDK operations.
///
/// Desktop callers continue to use c2patool for verification and signing.
/// Native SDK operations are currently available on iOS.
abstract interface class C2paPlatformAdapter {
  bool get usesNativeSdk;

  Future<String?> readManifestWithResources(
    String sourcePath,
    String outputDirectory,
  );

  Future<void> writeWithNativeSdk({
    required String sourcePath,
    required String outputPath,
    required C2paWriteMode mode,
  });
}

class DefaultC2paPlatformAdapter implements C2paPlatformAdapter {
  const DefaultC2paPlatformAdapter();

  @override
  bool get usesNativeSdk => MobileC2paService.isSupportedPlatform;

  @override
  Future<String?> readManifestWithResources(
    String sourcePath,
    String outputDirectory,
  ) {
    return MobileC2paService.readManifestWithResources(
      sourcePath,
      outputDirectory,
    );
  }

  @override
  Future<void> writeWithNativeSdk({
    required String sourcePath,
    required String outputPath,
    required C2paWriteMode mode,
  }) {
    return switch (mode) {
      C2paWriteMode.add => MobileC2paService.signMedia(
        sourcePath,
        outputPath,
        mode: C2paWriteModeNative.add,
      ),
      C2paWriteMode.replace => MobileC2paService.signMedia(
        sourcePath,
        outputPath,
        mode: C2paWriteModeNative.replace,
      ),
      C2paWriteMode.remove => MobileC2paService.removeC2pa(
        sourcePath,
        outputPath,
      ),
    };
  }
}
