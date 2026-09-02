import 'dart:io';

import 'package:c2pa_flutter/c2pa_flutter.dart';
// The public reader currently drops c2pa-rs validation results. Keep the raw
// JSON so the viewer can show the same validation detail as the desktop app.
// ignore: implementation_imports
import 'package:c2pa_flutter/src/rust/api/reader.dart' as c2pa_rust;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Mobile C2PA adapter backed by c2pa_flutter/c2pa-rs.
class MobileC2paService {
  MobileC2paService._();

  static bool get isSupportedPlatform => Platform.isIOS || Platform.isAndroid;

  static Future<void> initialize() => C2pa.init();

  static Future<String?> readManifestJson(String filePath) async {
    await initialize();
    final bytes = await File(filePath).readAsBytes();
    return c2pa_rust.readManifest(fileBytes: bytes, path: filePath);
  }

  static Future<void> signImage(String sourcePath, String outputPath) async {
    await initialize();
    final extension = p.extension(sourcePath).toLowerCase();
    final mimeType = switch (extension) {
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.png' => 'image/png',
      '.webp' => 'image/webp',
      '.tif' || '.tiff' => 'image/tiff',
      _ => throw UnsupportedError(
        'c2pa_flutter cannot sign ${extension.isEmpty ? 'this file' : extension} on mobile.',
      ),
    };

    final key = await rootBundle.load(
      'assets/c2pa/perfect_collage_private_pkcs8.key',
    );
    final certificate = await rootBundle.load(
      'assets/c2pa/perfect_collage_cert.pem',
    );
    final manifest =
        ManifestBuilder(
              claimGenerator: 'Perfect C2PA Mobile/1.0',
              title: p.basename(outputPath),
              format: mimeType,
            )
            .addAction(
              C2paActions.edited(
                description: 'Signed on mobile with Perfect C2PA',
                softwareAgent: 'Perfect C2PA Mobile/1.0',
              ),
            )
            .build();
    final signer = FileSigner(
      privateKeyPem: _bytes(key),
      certChainPem: _bytes(certificate),
      algorithm: SigningAlgorithm.es256,
    );
    final signedBytes = await C2pa.writer().sign(
      imageBytes: await File(sourcePath).readAsBytes(),
      mimeType: mimeType,
      manifest: manifest,
      signer: signer,
    );

    final destination = File(outputPath);
    await destination.parent.create(recursive: true);
    await destination.writeAsBytes(signedBytes, flush: true);
  }

  static Uint8List _bytes(ByteData data) =>
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}
