import 'package:c2pa_viewer/src/models.dart';
import 'package:c2pa_viewer/src/services/ai_metadata_service.dart';
import 'package:c2pa_viewer/src/services/media_inspection_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _AccessCheckingMetadataService extends AiMetadataService {
  _AccessCheckingMetadataService(this.isAccessActive);

  final bool Function() isAccessActive;

  @override
  Future<AiMediaMetadata> probe(String filePath) async {
    expect(isAccessActive(), isTrue);
    return const AiMediaMetadata(c2paStatus: C2paStatus.conformant);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('c2pa_viewer/media_probe');

  test(
    'keeps security-scoped access open for the complete inspection',
    () async {
      var accessActive = false;
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            switch (call.method) {
              case 'beginAccessingMedia':
                accessActive = true;
                return true;
              case 'probeMedia':
                expect(accessActive, isTrue);
                return <String, Object?>{
                  'width': 640,
                  'height': 480,
                  'durationSeconds': 0,
                  'hasAudio': false,
                  'isPhoto': true,
                };
              case 'endAccessingMedia':
                accessActive = false;
                return null;
            }
            throw MissingPluginException();
          });

      final service = MediaInspectionService(
        aiMetadataService: _AccessCheckingMetadataService(() => accessActive),
      );
      final clip = await service.inspect('/tmp/example.png');

      expect(clip.width, 640);
      expect(accessActive, isFalse);
      expect(calls.first, 'beginAccessingMedia');
      expect(calls.last, 'endAccessingMedia');
    },
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}
