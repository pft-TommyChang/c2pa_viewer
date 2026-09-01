import 'package:path/path.dart' as p;

enum MediaKind { video, photo }

String shortMediaTypeLabel(String path, MediaKind mediaKind) {
  return switch (p.extension(path).toLowerCase()) {
    '.jpg' || '.jpeg' => 'JPG',
    '.png' => 'PNG',
    '.webp' => 'WEBP',
    '.heic' => 'HEIC',
    '.heif' => 'HEIF',
    '.mp4' || '.m4v' => 'MP4',
    '.mov' => 'MOV',
    '.avi' => 'AVI',
    '.mkv' => 'MKV',
    _ => mediaKind == MediaKind.photo ? 'IMAGE' : 'VIDEO',
  };
}

enum C2paStatus {
  unknown,
  absent,
  untrusted,
  legacyTrusted,
  conformant,
  invalid,
}

class AiMediaMetadata {
  const AiMediaMetadata({
    this.c2paStatus = C2paStatus.unknown,
    this.vendor,
    this.model,
    this.c2paReport,
  });

  final C2paStatus c2paStatus;
  final String? vendor;
  final String? model;
  final C2paReport? c2paReport;

  bool get hasC2pa => switch (c2paStatus) {
    C2paStatus.untrusted ||
    C2paStatus.legacyTrusted ||
    C2paStatus.conformant ||
    C2paStatus.invalid => true,
    C2paStatus.unknown || C2paStatus.absent => false,
  };
}

class C2paReport {
  const C2paReport({
    required this.activeManifestLabel,
    required this.manifests,
    required this.validationEntries,
    required this.rawJson,
  });

  final String activeManifestLabel;
  final List<C2paManifest> manifests;
  final List<C2paValidationEntry> validationEntries;
  final String rawJson;

  C2paManifest? get activeManifest {
    for (final manifest in manifests) {
      if (manifest.label == activeManifestLabel) return manifest;
    }
    return manifests.isEmpty ? null : manifests.first;
  }

  int get passedCheckCount => validationEntries
      .where((entry) => entry.outcome == C2paValidationOutcome.passed)
      .length;

  int get failedCheckCount => validationEntries
      .where((entry) => entry.outcome == C2paValidationOutcome.failed)
      .length;
}

class C2paManifest {
  const C2paManifest({
    required this.label,
    this.title,
    this.format,
    this.instanceId,
    this.issuer,
    this.commonName,
    this.algorithm,
    this.signedAt,
    this.claimGenerator,
    this.thumbnailPath,
    this.actions = const <C2paAction>[],
    this.ingredients = const <C2paIngredient>[],
  });

  final String label;
  final String? title;
  final String? format;
  final String? instanceId;
  final String? issuer;
  final String? commonName;
  final String? algorithm;
  final String? signedAt;
  final String? claimGenerator;
  final String? thumbnailPath;
  final List<C2paAction> actions;
  final List<C2paIngredient> ingredients;
}

class C2paAction {
  const C2paAction({
    required this.action,
    this.softwareAgent,
    this.digitalSourceType,
  });

  final String action;
  final String? softwareAgent;
  final String? digitalSourceType;
}

class C2paIngredient {
  const C2paIngredient({
    this.title,
    this.format,
    this.relationship,
    this.instanceId,
    this.manifestLabel,
    this.thumbnailPath,
  });

  final String? title;
  final String? format;
  final String? relationship;
  final String? instanceId;
  final String? manifestLabel;
  final String? thumbnailPath;
}

enum C2paValidationOutcome { passed, failed, informational }

class C2paValidationEntry {
  const C2paValidationEntry({
    required this.code,
    required this.outcome,
    this.explanation,
  });

  final String code;
  final C2paValidationOutcome outcome;
  final String? explanation;
}

class VideoClipInfo {
  const VideoClipInfo({
    required this.path,
    required this.name,
    required this.duration,
    required this.width,
    required this.height,
    required this.hasAudio,
    required this.mediaKind,
    this.aiMetadata = const AiMediaMetadata(),
  });

  final String path;
  final String name;
  final Duration duration;
  final int width;
  final int height;
  final bool hasAudio;
  final MediaKind mediaKind;
  final AiMediaMetadata aiMetadata;

  String get id => path;
  bool get isVideo => mediaKind == MediaKind.video;
  bool get isPhoto => mediaKind == MediaKind.photo;
}
