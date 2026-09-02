import 'dart:convert';
import 'dart:io';

import 'package:c2pa_viewer/src/models.dart';
import 'package:c2pa_viewer/src/services/c2pa_test_sign_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'preserves the current claim as parent in a separate output file',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'c2pa_test_sign_service_test_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final source = File('${directory.path}/source.jpg');
      final output = File('${directory.path}/signed-source.jpg');
      await source.writeAsString('original media');
      final calls = <List<String>>[];
      Map<String, dynamic>? manifest;
      Map<String, dynamic>? parentIngredient;
      var usedScopedAccess = false;

      final service = C2paTestSignService(
        toolLocator: () => '/tools/c2patool',
        scopedFileAccess: (path, action) async {
          expect(path, source.path);
          usedScopedAccess = true;
          await action();
        },
        thumbnailGenerator: (sourcePath, outputPath) async {
          await File(outputPath).writeAsString('thumbnail');
          return true;
        },
        assetLoader: (assetPath) async => assetPath.endsWith('.key')
            ? 'test private key'
            : 'test signing certificate',
        processRunner: (executable, arguments) async {
          calls.add(arguments);
          final outputIndex = arguments.indexOf('--output');
          final outputPath = arguments[outputIndex + 1];
          if (arguments.contains('--ingredient')) {
            final parentDirectory = Directory(outputPath);
            await parentDirectory.create();
            await File(
              '${parentDirectory.path}/ingredient.json',
            ).writeAsString('{"format":"image/jpeg"}');
          } else {
            final manifestPath = arguments[arguments.indexOf('--manifest') + 1];
            manifest = jsonDecode(await File(manifestPath).readAsString());
            final parentPath = arguments[arguments.indexOf('--parent') + 1];
            parentIngredient = jsonDecode(
              await File('$parentPath/ingredient.json').readAsString(),
            );
            await File(outputPath).writeAsString('signed media');
          }
          return ProcessResult(1, 0, '', '');
        },
      );

      await service.write(
        VideoClipInfo(
          path: source.path,
          name: 'source.jpg',
          duration: Duration.zero,
          width: 100,
          height: 100,
          hasAudio: false,
          mediaKind: MediaKind.photo,
          aiMetadata: const AiMediaMetadata(c2paStatus: C2paStatus.conformant),
        ),
        output.path,
        C2paWriteMode.add,
      );

      expect(usedScopedAccess, isTrue);
      expect(await source.readAsString(), 'original media');
      expect(await output.readAsString(), 'signed media');
      expect(calls, hasLength(2));
      expect(calls.last, contains('--parent'));
      expect(manifest?['claim_generator'], 'Perfect C2PA Test Sign');
      expect(
        ((manifest?['assertions'] as List).first as Map)['label'],
        'c2pa.actions.v2',
      );
      expect(
        (parentIngredient?['thumbnail'] as Map)['identifier'],
        'parent/thumbnail.jpg',
      );
    },
  );

  test('creates a first claim without a parent for unsigned media', () async {
    final directory = await Directory.systemTemp.createTemp(
      'c2pa_first_test_sign_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final source = File('${directory.path}/source.png');
    final output = File('${directory.path}/signed-source.png');
    await source.writeAsString('unsigned media');
    List<String>? signArguments;

    final service = C2paTestSignService(
      toolLocator: () => '/tools/c2patool',
      scopedFileAccess: (_, action) => action(),
      thumbnailGenerator: (_, outputPath) async {
        await File(outputPath).writeAsString('thumbnail');
        return true;
      },
      assetLoader: (_) async => 'test key material',
      processRunner: (_, arguments) async {
        signArguments = arguments;
        final outputPath = arguments[arguments.indexOf('--output') + 1];
        await File(outputPath).writeAsString('signed media');
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.write(
      VideoClipInfo(
        path: source.path,
        name: 'source.png',
        duration: Duration.zero,
        width: 100,
        height: 100,
        hasAudio: false,
        mediaKind: MediaKind.photo,
        aiMetadata: const AiMediaMetadata(c2paStatus: C2paStatus.absent),
      ),
      output.path,
      C2paWriteMode.add,
    );

    expect(signArguments, isNot(contains('--parent')));
    expect(await source.readAsString(), 'unsigned media');
    expect(await output.readAsString(), 'signed media');
  });

  test('replaces existing C2PA without preserving a parent', () async {
    final directory = await Directory.systemTemp.createTemp(
      'c2pa_replace_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final source = File('${directory.path}/source.jpg');
    final output = File('${directory.path}/replaced.jpg');
    await source.writeAsString('media with old c2pa');
    List<String>? signArguments;
    String? signingInput;

    final service = C2paTestSignService(
      toolLocator: () => '/tools/c2patool',
      scopedFileAccess: (_, action) => action(),
      manifestRemover: (_, outputPath) async {
        await File(outputPath).writeAsString('media without c2pa');
      },
      thumbnailGenerator: (_, outputPath) async {
        await File(outputPath).writeAsString('thumbnail');
        return true;
      },
      assetLoader: (_) async => 'test key material',
      processRunner: (_, arguments) async {
        signArguments = arguments;
        signingInput = await File(arguments.first).readAsString();
        final outputPath = arguments[arguments.indexOf('--output') + 1];
        await File(outputPath).writeAsString('replacement c2pa');
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.write(
      VideoClipInfo(
        path: source.path,
        name: 'source.jpg',
        duration: Duration.zero,
        width: 100,
        height: 100,
        hasAudio: false,
        mediaKind: MediaKind.photo,
        aiMetadata: const AiMediaMetadata(c2paStatus: C2paStatus.conformant),
      ),
      output.path,
      C2paWriteMode.replace,
    );

    expect(signingInput, 'media without c2pa');
    expect(signArguments, isNot(contains('--parent')));
    expect(signArguments, containsAllInOrder(<String>['--create', 'empty']));
    expect(await source.readAsString(), 'media with old c2pa');
    expect(await output.readAsString(), 'replacement c2pa');
  });

  test('removes C2PA without invoking the signing tool', () async {
    final directory = await Directory.systemTemp.createTemp(
      'c2pa_remove_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final source = File('${directory.path}/source.png');
    await source.writeAsString('media with c2pa');

    final service = C2paTestSignService(
      toolLocator: () => throw StateError('c2patool should not be located'),
      scopedFileAccess: (_, action) => action(),
      manifestRemover: (_, outputPath) async {
        await File(outputPath).writeAsString('media without c2pa');
      },
      processRunner: (_, _) async => throw StateError('should not sign'),
    );

    await service.write(
      VideoClipInfo(
        path: source.path,
        name: 'source.png',
        duration: Duration.zero,
        width: 100,
        height: 100,
        hasAudio: false,
        mediaKind: MediaKind.photo,
        aiMetadata: const AiMediaMetadata(c2paStatus: C2paStatus.conformant),
      ),
      source.path,
      C2paWriteMode.remove,
    );

    expect(await source.readAsString(), 'media without c2pa');
  });
}
