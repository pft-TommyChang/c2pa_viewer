import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

typedef C2paTrustListDownloader = Future<List<int>> Function(Uri uri);
typedef C2paSupportDirectoryProvider = Future<Directory> Function();

class C2paTrustListVersion {
  const C2paTrustListVersion({
    required this.versionIdentifier,
    required this.sequenceNumber,
    required this.issueDate,
  });

  final int versionIdentifier;
  final int sequenceNumber;
  final DateTime issueDate;

  String get label => 'v$versionIdentifier.$sequenceNumber';
}

class C2paVerificationPlan {
  const C2paVerificationPlan({
    required this.officialArguments,
    this.legacyArguments,
  });

  final List<String> officialArguments;
  final List<String>? legacyArguments;
}

class C2paTrustListService {
  const C2paTrustListService({
    this.updateInterval = defaultUpdateInterval,
    C2paTrustListDownloader? downloader,
    C2paSupportDirectoryProvider? supportDirectoryProvider,
    DateTime Function()? now,
  }) : _downloader = downloader,
       _supportDirectoryProvider = supportDirectoryProvider,
       _now = now;

  static const Duration defaultUpdateInterval = Duration(hours: 24);

  static final Uri officialTrustListUri = Uri.parse(
    'https://raw.githubusercontent.com/c2pa-org/conformance-public/'
    'refs/heads/main/trust-list/C2PA-TRUST-LIST.pem',
  );
  static final Uri officialTrustListMetadataUri = Uri.parse(
    'https://raw.githubusercontent.com/c2pa-org/conformance-public/'
    'refs/heads/main/trust-list/C2PA-TRUST-LIST.json',
  );
  static final Uri legacyTrustAnchorsUri = Uri.parse(
    'https://verify.contentauthenticity.org/trust/anchors.pem',
  );
  static final Uri legacyAllowedListUri = Uri.parse(
    'https://verify.contentauthenticity.org/trust/allowed.sha256.txt',
  );
  static final Uri legacyTrustConfigUri = Uri.parse(
    'https://verify.contentauthenticity.org/trust/store.cfg',
  );
  static const String _trustListFileName = 'c2pa-trust-list.pem';
  static const String _legacyTrustListFileName = 'c2pa-trust-list-legacy.pem';
  static const String _metadataFileName = 'c2pa-trust-list.json';
  static const String _allowedListFileName = 'c2pa-trust-allowed.sha256.txt';
  static const String _trustConfigFileName = 'c2pa-trust-store.cfg';
  static const Duration _connectionTimeout = Duration(seconds: 10);
  static const Duration _responseTimeout = Duration(seconds: 15);
  static const int _maximumDownloadBytes = 2 * 1024 * 1024;

  final Duration updateInterval;
  final C2paTrustListDownloader? _downloader;
  final C2paSupportDirectoryProvider? _supportDirectoryProvider;
  final DateTime Function()? _now;

  Future<bool> refreshIfNeeded() async {
    final trustList = await _cachedTrustListFile();
    final legacyTrustList = _legacyTrustListBeside(trustList);
    final metadata = _metadataFileBeside(trustList);
    final allowedList = _allowedListBeside(trustList);
    final trustConfig = _trustConfigBeside(trustList);
    if (await _isFreshValidTrustList(trustList) &&
        await _isFreshValidTrustList(legacyTrustList) &&
        await _isFreshValidMetadata(metadata) &&
        await _isFreshValidAllowedList(allowedList) &&
        await _isFreshValidTrustConfig(trustConfig)) {
      return false;
    }

    try {
      final downloader = _downloader ?? _download;
      final downloads = await Future.wait<List<int>>(<Future<List<int>>>[
        downloader(officialTrustListUri),
        downloader(officialTrustListMetadataUri),
        downloader(legacyTrustAnchorsUri),
        downloader(legacyAllowedListUri),
        downloader(legacyTrustConfigUri),
      ]);
      final officialTrustListBytes = downloads[0];
      final metadataBytes = downloads[1];
      final legacyTrustAnchorsBytes = downloads[2];
      final allowedListBytes = downloads[3];
      final trustConfigBytes = downloads[4];
      if (!_isValidPem(officialTrustListBytes) ||
          !_isValidPem(legacyTrustAnchorsBytes)) {
        throw const FormatException('The C2PA trust list is not valid PEM.');
      }
      if (_parseVersion(metadataBytes) == null) {
        throw const FormatException(
          'The C2PA trust list metadata is not valid JSON.',
        );
      }
      if (!_isValidAllowedList(allowedListBytes)) {
        throw const FormatException('The C2PA allowed list is not valid.');
      }
      if (!_isValidTrustConfig(trustConfigBytes)) {
        throw const FormatException('The C2PA trust config is not valid.');
      }
      await _replaceFile(trustList, officialTrustListBytes);
      await _replaceFile(legacyTrustList, legacyTrustAnchorsBytes);
      await _replaceFile(metadata, metadataBytes);
      await _replaceFile(allowedList, allowedListBytes);
      await _replaceFile(trustConfig, trustConfigBytes);
      return true;
    } catch (_) {
      // Keep the last valid cached list, or let the caller use the bundled one.
      return false;
    }
  }

  Future<C2paTrustListVersion?> versionFor(String c2paToolPath) async {
    final cachedTrustList = await _cachedTrustListFile();
    final cachedVersion = await _versionForPair(cachedTrustList);
    if (cachedVersion != null) {
      return cachedVersion;
    }

    final bundledTrustList = File(
      p.join(p.dirname(c2paToolPath), _trustListFileName),
    );
    return _versionForPair(bundledTrustList);
  }

  Future<String?> settingsPathFor(String c2paToolPath) async {
    final cachedTrustList = await _cachedTrustListFile();
    if (await _isValidTrustListFile(cachedTrustList)) {
      return p.join(cachedTrustList.parent.path, 'c2pa.toml');
    }

    final bundledTrustList = File(
      p.join(p.dirname(c2paToolPath), _trustListFileName),
    );
    if (await _isValidTrustListFile(bundledTrustList)) {
      return p.join(bundledTrustList.parent.path, 'c2pa.toml');
    }
    return null;
  }

  Future<C2paVerificationPlan> verificationPlanFor(
    String c2paToolPath,
    String filePath,
  ) async {
    final cachedTrustList = await _cachedTrustListFile();
    final cachedPlan = await _verificationPlanForFiles(
      cachedTrustList,
      filePath,
    );
    if (cachedPlan != null) {
      return cachedPlan;
    }

    final bundledTrustList = File(
      p.join(p.dirname(c2paToolPath), _trustListFileName),
    );
    final bundledPlan = await _verificationPlanForFiles(
      bundledTrustList,
      filePath,
    );
    if (bundledPlan != null) {
      return bundledPlan;
    }

    final settingsPath = await settingsPathFor(c2paToolPath);
    return C2paVerificationPlan(
      officialArguments: settingsPath == null
          ? <String>[filePath]
          : <String>['--settings', settingsPath, filePath],
    );
  }

  Future<File> _cachedTrustListFile() async {
    final directory = await (_supportDirectoryProvider ?? _supportDirectory)();
    return File(p.join(directory.path, 'c2pa', _trustListFileName));
  }

  File _metadataFileBeside(File trustList) {
    return File(p.join(trustList.parent.path, _metadataFileName));
  }

  File _legacyTrustListBeside(File trustList) {
    return File(p.join(trustList.parent.path, _legacyTrustListFileName));
  }

  File _allowedListBeside(File trustList) {
    return File(p.join(trustList.parent.path, _allowedListFileName));
  }

  File _trustConfigBeside(File trustList) {
    return File(p.join(trustList.parent.path, _trustConfigFileName));
  }

  Future<C2paVerificationPlan?> _verificationPlanForFiles(
    File trustList,
    String filePath,
  ) async {
    if (!await _isValidTrustListFile(trustList)) {
      return null;
    }

    final legacyTrustList = _legacyTrustListBeside(trustList);
    final allowedList = _allowedListBeside(trustList);
    final trustConfig = _trustConfigBeside(trustList);
    final hasLegacyTrust =
        await _isValidTrustListFile(legacyTrustList) &&
        await _isValidAllowedListFile(allowedList) &&
        await _isValidTrustConfigFile(trustConfig);
    return C2paVerificationPlan(
      officialArguments: <String>[
        filePath,
        'trust',
        '--trust_anchors',
        trustList.path,
      ],
      legacyArguments: hasLegacyTrust
          ? <String>[
              filePath,
              'trust',
              '--trust_anchors',
              legacyTrustList.path,
              '--allowed_list',
              allowedList.path,
              '--trust_config',
              trustConfig.path,
            ]
          : null,
    );
  }

  Future<bool> _isFreshValidTrustList(File file) async {
    if (!await _isValidTrustListFile(file)) {
      return false;
    }
    final modified = await file.lastModified();
    final age = (_now ?? DateTime.now)().difference(modified);
    return !age.isNegative && age < updateInterval;
  }

  Future<bool> _isFreshValidMetadata(File file) async {
    if (await _versionFromFile(file) == null) {
      return false;
    }
    final modified = await file.lastModified();
    final age = (_now ?? DateTime.now)().difference(modified);
    return !age.isNegative && age < updateInterval;
  }

  Future<bool> _isFreshValidAllowedList(File file) async {
    if (!await _isValidAllowedListFile(file)) {
      return false;
    }
    return _isFresh(file);
  }

  Future<bool> _isFreshValidTrustConfig(File file) async {
    if (!await _isValidTrustConfigFile(file)) {
      return false;
    }
    return _isFresh(file);
  }

  Future<bool> _isFresh(File file) async {
    final modified = await file.lastModified();
    final age = (_now ?? DateTime.now)().difference(modified);
    return !age.isNegative && age < updateInterval;
  }

  Future<C2paTrustListVersion?> _versionForPair(File trustList) async {
    if (!await _isValidTrustListFile(trustList)) {
      return null;
    }
    return _versionFromFile(_metadataFileBeside(trustList));
  }

  Future<C2paTrustListVersion?> _versionFromFile(File file) async {
    try {
      if (!await file.exists() || await file.length() > _maximumDownloadBytes) {
        return null;
      }
      return _parseVersion(await file.readAsBytes());
    } catch (_) {
      return null;
    }
  }

  C2paTrustListVersion? _parseVersion(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > _maximumDownloadBytes) {
      return null;
    }
    try {
      final root = jsonDecode(utf8.decode(bytes));
      final lote = root is Map ? root['LoTE'] : null;
      final information = lote is Map ? lote['ListAndSchemeInformation'] : null;
      if (information is! Map) {
        return null;
      }
      final versionIdentifier = information['LoTEVersionIdentifier'];
      final sequenceNumber = information['LoTESequenceNumber'];
      final issueDate = DateTime.tryParse(
        information['ListIssueDateTime']?.toString() ?? '',
      );
      if (versionIdentifier is! num ||
          sequenceNumber is! num ||
          issueDate == null) {
        return null;
      }
      return C2paTrustListVersion(
        versionIdentifier: versionIdentifier.toInt(),
        sequenceNumber: sequenceNumber.toInt(),
        issueDate: issueDate,
      );
    } catch (_) {
      return null;
    }
  }

  Future<bool> _isValidTrustListFile(File file) async {
    try {
      if (!await file.exists() || await file.length() > _maximumDownloadBytes) {
        return false;
      }
      return _isValidPem(await file.readAsBytes());
    } catch (_) {
      return false;
    }
  }

  Future<bool> _isValidAllowedListFile(File file) async {
    return _isValidFile(file, _isValidAllowedList);
  }

  Future<bool> _isValidTrustConfigFile(File file) async {
    return _isValidFile(file, _isValidTrustConfig);
  }

  Future<bool> _isValidFile(
    File file,
    bool Function(List<int>) validator,
  ) async {
    try {
      if (!await file.exists() || await file.length() > _maximumDownloadBytes) {
        return false;
      }
      return validator(await file.readAsBytes());
    } catch (_) {
      return false;
    }
  }

  bool _isValidPem(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > _maximumDownloadBytes) {
      return false;
    }
    final source = utf8.decode(bytes, allowMalformed: true);
    return source.contains('-----BEGIN CERTIFICATE-----') &&
        source.contains('-----END CERTIFICATE-----');
  }

  bool _isValidAllowedList(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > _maximumDownloadBytes) {
      return false;
    }
    final lines = utf8
        .decode(bytes, allowMalformed: true)
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'));
    return lines.any((line) {
      try {
        return base64.decode(line).length == 32;
      } on FormatException {
        return false;
      }
    });
  }

  bool _isValidTrustConfig(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > _maximumDownloadBytes) {
      return false;
    }
    final source = utf8.decode(bytes, allowMalformed: true);
    return RegExp(r'^\s*\d+(?:\.\d+)+\s*$', multiLine: true).hasMatch(source);
  }

  Future<List<int>> _download(Uri uri) async {
    final client = HttpClient()..connectionTimeout = _connectionTimeout;
    try {
      final request = await client.getUrl(uri);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Perfect-C2PA-Trust-Updater',
      );
      final response = await request.close().timeout(_responseTimeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'C2PA trust list returned HTTP ${response.statusCode}.',
          uri: uri,
        );
      }

      final bytes = <int>[];
      await for (final chunk in response.timeout(_responseTimeout)) {
        if (bytes.length + chunk.length > _maximumDownloadBytes) {
          throw const FormatException('The C2PA trust list is too large.');
        }
        bytes.addAll(chunk);
      }
      return bytes;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _replaceFile(File target, List<int> bytes) async {
    await target.parent.create(recursive: true);
    final suffix = '${pid}_${(_now ?? DateTime.now)().microsecondsSinceEpoch}';
    final temporary = File('${target.path}.$suffix.tmp');
    final backup = File('${target.path}.$suffix.backup');
    await temporary.writeAsBytes(bytes, flush: true);

    try {
      if (await target.exists()) {
        await target.rename(backup.path);
      }
      try {
        await temporary.rename(target.path);
        if (await backup.exists()) {
          await backup.delete();
        }
      } catch (_) {
        if (!await target.exists() && await backup.exists()) {
          await backup.rename(target.path);
        }
        rethrow;
      }
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  Future<Directory> _supportDirectory() async {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData == null || appData.isEmpty) {
        throw const FileSystemException('APPDATA is not available.');
      }
      return Directory(p.join(appData, 'c2pa_viewer'));
    }

    final homeDirectory = Platform.environment['HOME'];
    if (homeDirectory == null || homeDirectory.isEmpty) {
      throw const FileSystemException('HOME is not available.');
    }
    if (Platform.isMacOS) {
      return Directory(
        p.join(homeDirectory, 'Library', 'Application Support', 'c2pa_viewer'),
      );
    }
    final dataHome = Platform.environment['XDG_DATA_HOME'];
    return Directory(
      dataHome == null || dataHome.isEmpty
          ? p.join(homeDirectory, '.local', 'share', 'c2pa_viewer')
          : p.join(dataHome, 'c2pa_viewer'),
    );
  }
}
