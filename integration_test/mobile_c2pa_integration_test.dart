import 'dart:convert';
import 'dart:io';

import 'package:c2pa_viewer/src/services/mobile_c2pa_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('c2pa_flutter reads and signs an image on mobile', (_) async {
    final directory = await Directory.systemTemp.createTemp(
      'perfect_c2pa_mobile_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final source = File('${directory.path}/source.png');
    final output = File('${directory.path}/signed.png');
    final asset = await rootBundle.load('assets/app_icon_1024.png');
    await source.writeAsBytes(asset.buffer.asUint8List());

    expect(await MobileC2paService.readManifestJson(source.path), isNull);
    await MobileC2paService.signImage(source.path, output.path);

    final signedJson = await MobileC2paService.readManifestJson(output.path);
    expect(signedJson, isNotNull);
    final store = jsonDecode(signedJson!) as Map<String, dynamic>;
    expect(store['active_manifest'], isNotNull);
    expect(store['manifests'], isNotEmpty);
  });
}
