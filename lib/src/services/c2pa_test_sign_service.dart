import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models.dart';
import 'ai_metadata_service.dart';
import 'c2pa_platform_adapter.dart';
import 'c2pa_write_models.dart';
import 'media_inspection_service.dart';

export 'c2pa_write_models.dart';

typedef C2paSignProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);
typedef C2paSignThumbnailGenerator =
    Future<bool> Function(String sourcePath, String outputPath);
typedef C2paSignAssetLoader = Future<String> Function(String assetPath);
typedef C2paManifestRemover =
    Future<void> Function(String sourcePath, String outputPath);
typedef C2paScopedFileAccess =
    Future<void> Function(String path, Future<void> Function() action);
typedef C2paTestWriter =
    Future<void> Function(
      VideoClipInfo clip,
      String outputPath,
      C2paWriteMode mode,
    );

class C2paTestSignException implements Exception {
  const C2paTestSignException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Adds, replaces, or removes C2PA for a development write test.
///
/// Add mode preserves existing Content Credentials as the parent ingredient.
/// Every mode writes through a temporary file before replacing its target.
class C2paTestSignService {
  static const _signingCertificateAsset =
      'assets/c2pa/perfect_collage_cert.pem';
  static const _signingPrivateKeyAsset =
      'assets/c2pa/perfect_collage_private.key';

  const C2paTestSignService({
    C2paSignProcessRunner? processRunner,
    C2paSignThumbnailGenerator? thumbnailGenerator,
    C2paSignAssetLoader? assetLoader,
    C2paManifestRemover? manifestRemover,
    String? Function()? toolLocator,
    C2paScopedFileAccess? scopedFileAccess,
    C2paPlatformAdapter? platformAdapter,
  }) : _processRunner = processRunner ?? _runProcess,
       _thumbnailGenerator = thumbnailGenerator ?? _generateThumbnail,
       _assetLoader = assetLoader ?? _loadAsset,
       _manifestRemover = manifestRemover ?? MediaInspectionService.removeC2pa,
       _toolLocator = toolLocator ?? AiMetadataService.findC2paTool,
       _scopedFileAccess =
           scopedFileAccess ?? MediaInspectionService.withSecurityScopedAccess,
       _platformAdapter = platformAdapter ?? const DefaultC2paPlatformAdapter();

  final C2paSignProcessRunner _processRunner;
  final C2paSignThumbnailGenerator _thumbnailGenerator;
  final C2paSignAssetLoader _assetLoader;
  final C2paManifestRemover _manifestRemover;
  final String? Function() _toolLocator;
  final C2paScopedFileAccess _scopedFileAccess;
  final C2paPlatformAdapter _platformAdapter;

  Future<void> write(
    VideoClipInfo clip,
    String outputPath,
    C2paWriteMode mode,
  ) async {
    if (_platformAdapter.usesNativeSdk) {
      try {
        await _platformAdapter.writeWithNativeSdk(
          sourcePath: clip.path,
          outputPath: outputPath,
          mode: mode,
        );
      } on UnsupportedError catch (error) {
        throw C2paTestSignException(
          error.message ?? 'Unsupported format on mobile.',
        );
      } on Object catch (error) {
        throw C2paTestSignException(
          'Could not complete mobile C2PA operation: $error',
        );
      }
      return;
    }
    final executable = mode == C2paWriteMode.remove ? null : _toolLocator();
    if (mode != C2paWriteMode.remove && executable == null) {
      throw const C2paTestSignException(
        'c2patool is not available, so the media could not be signed.',
      );
    }

    await _scopedFileAccess(clip.path, () async {
      final workDirectory = await Directory.systemTemp.createTemp(
        'perfect_c2pa_test_sign_',
      );
      try {
        await _signInWorkDirectory(
          clip: clip,
          outputPath: outputPath,
          mode: mode,
          executable: executable,
          workDirectory: workDirectory,
        );
      } on C2paTestSignException {
        rethrow;
      } on Object catch (error) {
        throw C2paTestSignException(
          'Could not complete the C2PA write test: $error',
        );
      } finally {
        if (await workDirectory.exists()) {
          await workDirectory.delete(recursive: true);
        }
      }
    });
  }

  Future<void> _signInWorkDirectory({
    required VideoClipInfo clip,
    required String outputPath,
    required C2paWriteMode mode,
    required String? executable,
    required Directory workDirectory,
  }) async {
    final extension = p.extension(clip.path).toLowerCase();
    final stagedSource = p.join(workDirectory.path, 'source$extension');
    await File(clip.path).copy(stagedSource);

    if (mode == C2paWriteMode.remove) {
      if (!clip.aiMetadata.hasC2pa) {
        await File(stagedSource).copy(outputPath);
        return;
      }
      final strippedPath = p.join(workDirectory.path, 'stripped$extension');
      await _manifestRemover(stagedSource, strippedPath);
      await File(strippedPath).copy(outputPath);
      return;
    }

    var signingSource = stagedSource;
    if (mode == C2paWriteMode.replace && clip.aiMetadata.hasC2pa) {
      signingSource = p.join(workDirectory.path, 'stripped$extension');
      await _manifestRemover(stagedSource, signingSource);
    }

    String? parentDirectoryPath;
    if (mode == C2paWriteMode.add && clip.aiMetadata.hasC2pa) {
      final parentDirectory = Directory(p.join(workDirectory.path, 'parent'));
      final ingredientResult = await _processRunner(executable!, <String>[
        stagedSource,
        '--ingredient',
        '--output',
        parentDirectory.path,
      ]);
      _requireSuccess(
        ingredientResult,
        'Could not preserve the current C2PA claim',
      );
      await _prepareParentIngredient(
        sourcePath: stagedSource,
        parentDirectory: parentDirectory,
      );
      parentDirectoryPath = parentDirectory.path;
    }

    final claimThumbnailPath = p.join(
      workDirectory.path,
      'claim-thumbnail.jpg',
    );
    final generatedThumbnail = await _thumbnailGenerator(
      signingSource,
      claimThumbnailPath,
    );
    if (!generatedThumbnail || !await File(claimThumbnailPath).exists()) {
      throw const C2paTestSignException(
        'Could not create the Content Credentials thumbnail.',
      );
    }

    final signingCertificatePath = p.join(
      workDirectory.path,
      'perfect_collage_cert.pem',
    );
    final signingPrivateKeyPath = p.join(
      workDirectory.path,
      'perfect_collage_private.key',
    );
    await Future.wait(<Future<File>>[
      File(
        signingCertificatePath,
      ).writeAsString(await _assetLoader(_signingCertificateAsset)),
      File(
        signingPrivateKeyPath,
      ).writeAsString(await _assetLoader(_signingPrivateKeyAsset)),
    ]);

    final manifestFile = File(p.join(workDirectory.path, 'manifest.json'));
    await manifestFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(
        _buildManifest(
          title: p.basename(clip.path),
          signingCertificatePath: signingCertificatePath,
          signingPrivateKeyPath: signingPrivateKeyPath,
        ),
      ),
    );
    final signedPath = p.join(workDirectory.path, 'signed$extension');
    final signResult = await _processRunner(executable!, <String>[
      signingSource,
      '--manifest',
      manifestFile.path,
      if (mode == C2paWriteMode.replace) ...const <String>['--create', 'empty'],
      if (parentDirectoryPath != null) ...<String>[
        '--parent',
        parentDirectoryPath,
      ],
      '--force',
      '--output',
      signedPath,
    ]);
    _requireSuccess(signResult, 'Could not sign the selected media');
    if (!await File(signedPath).exists()) {
      throw const C2paTestSignException(
        'c2patool did not produce a signed media file.',
      );
    }
    await File(signedPath).copy(outputPath);
  }

  Future<void> _prepareParentIngredient({
    required String sourcePath,
    required Directory parentDirectory,
  }) async {
    final ingredientFile = File(
      p.join(parentDirectory.path, 'ingredient.json'),
    );
    if (!await ingredientFile.exists()) {
      throw const C2paTestSignException(
        'c2patool did not produce a parent ingredient.',
      );
    }
    final decoded = jsonDecode(await ingredientFile.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const C2paTestSignException(
        'c2patool produced an invalid parent ingredient.',
      );
    }
    if (decoded['thumbnail'] is! Map) {
      final thumbnailPath = p.join(parentDirectory.path, 'thumbnail.jpg');
      final generated = await _thumbnailGenerator(sourcePath, thumbnailPath);
      if (!generated || !await File(thumbnailPath).exists()) {
        throw const C2paTestSignException(
          'Could not create a thumbnail for the parent C2PA claim.',
        );
      }
      decoded['thumbnail'] = <String, String>{
        'format': 'image/jpeg',
        'identifier': 'thumbnail.jpg',
      };
    }
    for (final key in const <String>['thumbnail', 'manifest_data']) {
      final resource = decoded[key];
      if (resource is Map && resource['identifier'] is String) {
        resource['identifier'] = p.posix.join(
          'parent',
          resource['identifier'] as String,
        );
      }
    }
    await ingredientFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(decoded),
    );
  }

  static Map<String, dynamic> _buildManifest({
    required String title,
    required String signingCertificatePath,
    required String signingPrivateKeyPath,
  }) {
    return <String, dynamic>{
      'claim_generator': 'Perfect C2PA Test Sign',
      'claim_generator_info': <Map<String, String>>[
        <String, String>{'name': 'Perfect C2PA Test Sign'},
      ],
      'title': title,
      'assertions': <Map<String, dynamic>>[
        <String, dynamic>{
          'label': 'c2pa.actions.v2',
          'data': <String, dynamic>{
            'actions': <Map<String, String>>[
              <String, String>{
                'action': 'c2pa.edited',
                'softwareAgent': 'Perfect C2PA Test Sign',
              },
            ],
          },
        },
      ],
      'thumbnail': <String, String>{
        'format': 'image/jpeg',
        'identifier': 'claim-thumbnail.jpg',
      },
      'sign_cert': signingCertificatePath,
      'private_key': signingPrivateKeyPath,
      'alg': 'es256',
    };
  }

  static void _requireSuccess(ProcessResult result, String message) {
    if (result.exitCode == 0) return;
    final details = '${result.stderr}'.trim();
    throw C2paTestSignException(
      details.isEmpty ? message : '$message: $details',
    );
  }

  static Future<bool> _generateThumbnail(
    String sourcePath,
    String outputPath,
  ) async {
    final bytes = await MediaInspectionService.thumbnail(sourcePath);
    if (bytes == null) return false;
    await File(outputPath).writeAsBytes(bytes);
    return true;
  }

  static Future<String> _loadAsset(String assetPath) {
    return rootBundle.loadString(assetPath);
  }

  static Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments,
  ) {
    return Process.run(executable, arguments);
  }
}
