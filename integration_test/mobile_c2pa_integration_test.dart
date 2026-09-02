import 'dart:convert';
import 'dart:io';

import 'package:c2pa_viewer/src/services/mobile_c2pa_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native C2PA reads and signs an image on mobile', (_) async {
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
    await MobileC2paService.signMedia(source.path, output.path);

    final signedJson = await MobileC2paService.readManifestJson(output.path);
    expect(signedJson, isNotNull);
    final store = jsonDecode(signedJson!) as Map<String, dynamic>;
    expect(store['active_manifest'], isNotNull);
    expect(store['manifests'], isNotEmpty);

    final addedAgain = File('${directory.path}/added-again.png');
    await MobileC2paService.signMedia(output.path, addedAgain.path);
    final addedStore =
        jsonDecode((await MobileC2paService.readManifestJson(addedAgain.path))!)
            as Map<String, dynamic>;
    expect((addedStore['manifests'] as Map<String, dynamic>).length, 2);

    final replaced = File('${directory.path}/replaced.png');
    await MobileC2paService.signMedia(
      addedAgain.path,
      replaced.path,
      mode: C2paWriteModeNative.replace,
    );
    final replacedStore =
        jsonDecode((await MobileC2paService.readManifestJson(replaced.path))!)
            as Map<String, dynamic>;
    expect((replacedStore['manifests'] as Map<String, dynamic>).length, 1);
  });

  testWidgets('native C2PA signs an MP4 video on mobile', (_) async {
    const fixture =
        'AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAN0bW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAAMgAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAp90cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAAMgAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAACAAAAAgAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAADIAAAEAAABAAAAAAIXbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAyAAAACgBVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABwm1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAYJzdGJsAAAAvnN0c2QAAAAAAAAAAQAAAK5hdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAACAAIABIAAAASAAAAAAAAAABFUxhdmM2Mi4xMS4xMDAgbGlieDI2NAAAAAAAAAAAAAAAGP//AAAANGF2Y0MBZAAK/+EAF2dkAAqs2UlsBEAAAAMAQAAADIPEiWWAAQAGaOvjyyLA/fj4AAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAAHcQAAAAAAAAABhzdHRzAAAAAAAAAAEAAAAFAAACAAAAABRzdHNzAAAAAAAAAAEAAAABAAAAOGN0dHMAAAAAAAAABQAAAAEAAAQAAAAAAQAACgAAAAABAAAEAAAAAAEAAAAAAAAAAQAAAgAAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAUAAAABAAAAKHN0c3oAAAAAAAAAAAAAAAUAAALKAAAADAAAAAwAAAAMAAAADAAAABRzdGNvAAAAAAAAAAEAAAOkAAAAYXVkdGEAAABZbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAsaWxzdAAAACSpdG9vAAAAHGRhdGEAAAABAAAAAExhdmY2Mi4zLjEwMAAAAAhmcmVlAAADAm1kYXQAAAKuBgX//6rcRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MSByZWY9MyBkZWJsb2NrPTE6MDowIGFuYWx5c2U9MHgzOjB4MTEzIG1lPWhleCBzdWJtZT03IHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTEgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0xIDh4OGRjdD0xIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PS0yIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTMgYl9weXJhbWlkPTIgYl9hZGFwdD0xIGJfYmlhcz0wIGRpcmVjdD0xIHdlaWdodGI9MSBvcGVuX2dvcD0wIHdlaWdodHA9MiBrZXlpbnQ9MjUwIGtleWludF9taW49MjUgc2NlbmVjdXQ9NDAgaW50cmFfcmVmcmVzaD0wIHJjX2xvb2thaGVhZD00MCByYz1jcmYgbWJ0cmVlPTEgY3JmPTIzLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MToxLjAwAIAAAAAUZYiEADP//vbsvgU2FMhQlnnHF8EAAAAIQZokbEK//lYAAAAIQZ5CeIX/VcEAAAAIAZ5hdEK/WsAAAAAIAZ5jakK/WsE=';
    final directory = await Directory.systemTemp.createTemp(
      'perfect_c2pa_video_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final source = File('${directory.path}/source.mp4');
    final output = File('${directory.path}/signed.mp4');
    await source.writeAsBytes(base64Decode(fixture));

    await MobileC2paService.signMedia(source.path, output.path);

    final signedJson = await MobileC2paService.readManifestJson(output.path);
    expect(signedJson, isNotNull);
    final store = jsonDecode(signedJson!) as Map<String, dynamic>;
    expect(store['active_manifest'], isNotNull);
  });
}
