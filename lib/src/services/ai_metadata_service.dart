import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models.dart';
import 'c2pa_trust_list_service.dart';
import 'mobile_c2pa_service.dart';

class AiMetadataService {
  const AiMetadataService({
    this.trustListService = const C2paTrustListService(),
  });

  final C2paTrustListService trustListService;
  static final Set<String> _temporaryResourceDirectories = <String>{};

  static void cleanupExtractedResources() {
    for (final path in _temporaryResourceDirectories.toList()) {
      try {
        final directory = Directory(path);
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      } on FileSystemException {
        // The operating system will eventually clear abandoned temp files.
      }
      _temporaryResourceDirectories.remove(path);
    }
  }

  Future<bool> refreshTrustListIfNeeded() {
    return trustListService.refreshIfNeeded();
  }

  Future<C2paTrustListVersion?> trustListVersion() async {
    final executable = findC2paTool();
    return executable == null ? null : trustListService.versionFor(executable);
  }

  Future<AiMediaMetadata> probe(String filePath) async {
    return probeC2pa(filePath);
  }

  Future<AiMediaMetadata> probeC2pa(String filePath) async {
    if (MobileC2paService.isSupportedPlatform) {
      try {
        final source = await MobileC2paService.readManifestJson(filePath);
        if (source == null) {
          return const AiMediaMetadata(c2paStatus: C2paStatus.absent);
        }
        return parseC2paJson(source);
      } on FormatException {
        return const AiMediaMetadata(c2paStatus: C2paStatus.invalid);
      } on Object {
        return const AiMediaMetadata(c2paStatus: C2paStatus.unknown);
      }
    }
    final executable = findC2paTool();
    if (executable == null) {
      return const AiMediaMetadata();
    }

    String? temporaryRootPath;
    try {
      final plan = await trustListService.verificationPlanFor(
        executable,
        filePath,
      );
      final temporaryRoot = await Directory.systemTemp.createTemp(
        'c2pa_viewer_report_',
      );
      temporaryRootPath = temporaryRoot.path;
      _temporaryResourceDirectories.add(temporaryRoot.path);
      final resourceDirectory = p.join(temporaryRoot.path, 'report');
      final result = await Process.run(executable, <String>[
        '--output',
        resourceDirectory,
        ...plan.officialArguments,
      ]);
      final manifestStoreFile = File(
        p.join(resourceDirectory, 'manifest_store.json'),
      );
      if (!await manifestStoreFile.exists()) {
        _discardTemporaryResources(temporaryRoot.path);
        final message = '${result.stdout}\n${result.stderr}'.toLowerCase();
        return AiMediaMetadata(
          c2paStatus: message.contains('no claim found')
              ? C2paStatus.absent
              : C2paStatus.invalid,
        );
      }
      final source = await manifestStoreFile.readAsString();
      final official = parseC2paJson(
        source,
        resourceDirectory: resourceDirectory,
      );
      if (official.c2paStatus != C2paStatus.untrusted ||
          plan.legacyArguments == null) {
        return official;
      }

      // Content Authenticity Verify checks its legacy store only when the
      // credential is not in the official C2PA conformance trust list.
      final legacyResult = await Process.run(executable, plan.legacyArguments!);
      if (legacyResult.exitCode != 0) {
        return official;
      }
      try {
        final legacy = parseC2paJson(
          legacyResult.stdout as String,
          trustedStatus: C2paStatus.legacyTrusted,
          resourceDirectory: resourceDirectory,
        );
        return legacy.c2paStatus == C2paStatus.legacyTrusted
            ? legacy
            : official;
      } on FormatException {
        return official;
      }
    } on FormatException {
      if (temporaryRootPath != null) {
        _discardTemporaryResources(temporaryRootPath);
      }
      return const AiMediaMetadata(c2paStatus: C2paStatus.invalid);
    } on FileSystemException {
      if (temporaryRootPath != null) {
        _discardTemporaryResources(temporaryRootPath);
      }
      return const AiMediaMetadata();
    } on ProcessException {
      if (temporaryRootPath != null) {
        _discardTemporaryResources(temporaryRootPath);
      }
      return const AiMediaMetadata();
    }
  }

  static void _discardTemporaryResources(String path) {
    try {
      final directory = Directory(path);
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    } on FileSystemException {
      // Best-effort cleanup for a failed probe.
    }
    _temporaryResourceDirectories.remove(path);
  }

  static String? findC2paTool() {
    final executableDirectory = p.dirname(Platform.resolvedExecutable);
    final executableName = Platform.isWindows ? 'c2patool.exe' : 'c2patool';
    final pathCandidates = (Platform.environment['PATH'] ?? '')
        .split(Platform.isWindows ? ';' : ':')
        .where((directory) => directory.isNotEmpty)
        .map((directory) => p.join(directory, executableName));
    final candidates = <String>[
      p.join(executableDirectory, executableName),
      p.normalize(
        p.join(executableDirectory, '..', 'Resources', executableName),
      ),
      '/opt/homebrew/bin/c2patool',
      '/usr/local/bin/c2patool',
      ...pathCandidates,
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }
    return null;
  }

  static AiMediaMetadata parseC2paJson(
    String source, {
    C2paStatus trustedStatus = C2paStatus.conformant,
    String? resourceDirectory,
  }) {
    final root = jsonDecode(source);
    if (root is! Map<String, dynamic>) {
      throw const FormatException('C2PA output is not an object.');
    }
    final manifests = root['manifests'];
    if (manifests is! Map || manifests.isEmpty) {
      return const AiMediaMetadata(c2paStatus: C2paStatus.absent);
    }

    final activeLabel = root['active_manifest'];
    final active = manifests[activeLabel] ?? manifests.values.first;
    if (active is! Map) {
      return const AiMediaMetadata(c2paStatus: C2paStatus.invalid);
    }

    String? vendor;
    String? model;
    final signatureInfo = active['signature_info'];
    if (signatureInfo is Map) {
      vendor =
          _nonEmptyString(signatureInfo['issuer']) ??
          _nonEmptyString(signatureInfo['common_name']);
    }

    final assertions = active['assertions'];
    if (assertions is List) {
      for (final assertion in assertions.whereType<Map>()) {
        final label = _nonEmptyString(assertion['label']);
        final data = assertion['data'];
        if (label == 'c2pa.ai-disclosure' && data is Map) {
          model ??= _nonEmptyString(data['modelName']);
        }
        if (label == 'c2pa.creative_work' && data is Map) {
          final authors = data['author'];
          if (authors is List && authors.isNotEmpty && authors.first is Map) {
            vendor ??= _nonEmptyString((authors.first as Map)['name']);
          }
        }
        if (label != 'c2pa.actions.v2' || data is! Map) {
          continue;
        }
        final actions = data['actions'];
        if (actions is! List) {
          continue;
        }
        for (final action in actions.whereType<Map>()) {
          final parameters = action['parameters'];
          if (parameters is Map) {
            model ??= _nonEmptyString(parameters['model_name']);
          }
        }
      }
    }

    final validationStatuses = root['validation_status'];
    final validationCodes = validationStatuses is List
        ? validationStatuses
              .whereType<Map>()
              .map((item) => _nonEmptyString(item['code']))
              .whereType<String>()
              .toSet()
        : const <String>{};
    final validationResults = root['validation_results'];
    final activeManifest = validationResults is Map
        ? validationResults['activeManifest']
        : null;
    final successes = activeManifest is Map ? activeManifest['success'] : null;
    final successCodes = successes is List
        ? successes
              .whereType<Map>()
              .map((item) => _nonEmptyString(item['code']))
              .whereType<String>()
              .toSet()
        : const <String>{};
    final hasUntrustedCredential = validationCodes.any(
      (code) =>
          code == 'signingCredential.untrusted' ||
          code == 'signingCredential.untrustedIndefinite',
    );
    final hasValidationFailure = validationCodes.any(
      (code) =>
          code != 'signingCredential.untrusted' &&
          code != 'signingCredential.untrustedIndefinite',
    );
    final hasTrustedCredential = successCodes.contains(
      'signingCredential.trusted',
    );
    final hasValidSignature = successCodes.contains('claimSignature.validated');
    final status = hasValidationFailure
        ? C2paStatus.invalid
        : hasTrustedCredential
        ? trustedStatus
        : hasUntrustedCredential || hasValidSignature
        ? C2paStatus.untrusted
        : C2paStatus.invalid;

    return AiMediaMetadata(
      c2paStatus: status,
      vendor: vendor,
      model: model,
      c2paReport: _parseC2paReport(root, resourceDirectory),
    );
  }

  static C2paReport _parseC2paReport(
    Map<String, dynamic> root,
    String? resourceDirectory,
  ) {
    final rawManifests = root['manifests'] as Map;
    final manifests = <C2paManifest>[];
    for (final entry in rawManifests.entries) {
      final manifest = entry.value;
      if (manifest is! Map) continue;
      final signature = manifest['signature_info'];
      final actions = <C2paAction>[];
      final assertions = manifest['assertions'];
      if (assertions is List) {
        for (final assertion in assertions.whereType<Map>()) {
          final assertionData = assertion['data'];
          if (assertionData is! Map) continue;
          final rawActions = assertionData['actions'];
          if (rawActions is! List) continue;
          for (final rawAction in rawActions.whereType<Map>()) {
            final parameters = rawAction['parameters'];
            actions.add(
              C2paAction(
                action:
                    _nonEmptyString(rawAction['action']) ?? 'Unknown action',
                softwareAgent: _displayString(rawAction['softwareAgent']),
                digitalSourceType:
                    _nonEmptyString(rawAction['digitalSourceType']) ??
                    (parameters is Map
                        ? _nonEmptyString(parameters['digital_source_type'])
                        : null),
              ),
            );
          }
        }
      }
      final ingredients = <C2paIngredient>[];
      final rawIngredients = manifest['ingredients'];
      if (rawIngredients is List) {
        for (final ingredient in rawIngredients.whereType<Map>()) {
          ingredients.add(
            C2paIngredient(
              title: _nonEmptyString(ingredient['title']),
              format: _nonEmptyString(ingredient['format']),
              relationship: _nonEmptyString(ingredient['relationship']),
              instanceId: _nonEmptyString(ingredient['instance_id']),
              manifestLabel:
                  _nonEmptyString(ingredient['active_manifest']) ??
                  _nonEmptyString(ingredient['manifest_label']),
              thumbnailPath: _resourcePathFor(
                resourceDirectory,
                ingredient['thumbnail'],
              ),
            ),
          );
        }
      }
      manifests.add(
        C2paManifest(
          label: entry.key.toString(),
          title: _nonEmptyString(manifest['title']),
          format: _nonEmptyString(manifest['format']),
          instanceId: _nonEmptyString(manifest['instance_id']),
          issuer: signature is Map
              ? _nonEmptyString(signature['issuer'])
              : null,
          commonName: signature is Map
              ? _nonEmptyString(signature['common_name'])
              : null,
          algorithm: signature is Map
              ? _nonEmptyString(signature['alg']) ??
                    _nonEmptyString(signature['algorithm'])
              : null,
          signedAt: signature is Map
              ? _nonEmptyString(signature['time']) ??
                    _nonEmptyString(signature['signed_at'])
              : null,
          claimGenerator:
              _displayString(manifest['claim_generator_info']) ??
              _displayString(manifest['claim_generator']),
          thumbnailPath: _resourcePathFor(
            resourceDirectory,
            manifest['thumbnail'],
          ),
          actions: actions,
          ingredients: ingredients,
        ),
      );
    }

    final validations = <C2paValidationEntry>[];
    void collectValidations(dynamic value, C2paValidationOutcome outcome) {
      if (value is List) {
        for (final item in value) {
          collectValidations(item, outcome);
        }
      } else if (value is Map) {
        final code = _nonEmptyString(value['code']);
        if (code != null) {
          validations.add(
            C2paValidationEntry(
              code: code,
              outcome: outcome,
              explanation:
                  _nonEmptyString(value['explanation']) ??
                  _nonEmptyString(value['message']),
            ),
          );
        }
        for (final entry in value.entries) {
          final key = entry.key.toString().toLowerCase();
          final nestedOutcome = key == 'success'
              ? C2paValidationOutcome.passed
              : key == 'failure' || key == 'failures' || key == 'error'
              ? C2paValidationOutcome.failed
              : key == 'informational'
              ? C2paValidationOutcome.informational
              : outcome;
          collectValidations(entry.value, nestedOutcome);
        }
      }
    }

    collectValidations(
      root['validation_results'],
      C2paValidationOutcome.informational,
    );
    final topLevelStatus = root['validation_status'];
    if (topLevelStatus is List) {
      for (final statusItem in topLevelStatus.whereType<Map>()) {
        final code = _nonEmptyString(statusItem['code']);
        if (code != null && !validations.any((item) => item.code == code)) {
          validations.add(
            C2paValidationEntry(
              code: code,
              outcome: code.startsWith('signingCredential.untrusted')
                  ? C2paValidationOutcome.informational
                  : C2paValidationOutcome.failed,
              explanation:
                  _nonEmptyString(statusItem['explanation']) ??
                  _nonEmptyString(statusItem['message']),
            ),
          );
        }
      }
    }

    return C2paReport(
      activeManifestLabel:
          _nonEmptyString(root['active_manifest']) ??
          (manifests.isEmpty ? '' : manifests.first.label),
      manifests: List<C2paManifest>.unmodifiable(manifests),
      validationEntries: List<C2paValidationEntry>.unmodifiable(validations),
      rawJson: const JsonEncoder.withIndent('  ').convert(root),
    );
  }

  static String? _displayString(dynamic value) {
    if (value is String) return _nonEmptyString(value);
    if (value is List && value.isNotEmpty) return _displayString(value.first);
    if (value is Map) {
      final name =
          _nonEmptyString(value['name']) ?? _nonEmptyString(value['product']);
      final version = _nonEmptyString(value['version']);
      if (name != null && version != null) return '$name $version';
      return name ?? version;
    }
    return null;
  }

  static String? _resourcePathFor(
    String? resourceDirectory,
    dynamic reference,
  ) {
    if (resourceDirectory == null || reference is! Map) return null;
    final identifier = _nonEmptyString(reference['identifier']);
    if (identifier == null) return null;
    const prefix = 'self#jumbf=/c2pa/';
    if (!identifier.startsWith(prefix)) return null;
    final segments = identifier.substring(prefix.length).split('/');
    if (segments.length < 2) return null;
    final manifestDirectory = segments.first.replaceAll(':', '_');
    final candidate = File(
      p.joinAll(<String>[
        resourceDirectory,
        manifestDirectory,
        ...segments.skip(1),
      ]),
    );
    return candidate.existsSync() ? candidate.path : null;
  }

  static String? _nonEmptyString(dynamic value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
