import 'dart:convert';
import 'dart:io';

class GitHubRelease {
  const GitHubRelease({required this.tagName, required this.pageUrl});

  final String tagName;
  final Uri pageUrl;

  String get version => tagName.replaceFirst(RegExp(r'^[vV]'), '');
}

class GitHubUpdateService {
  const GitHubUpdateService({required this.owner, required this.repository});

  static const Duration _connectionTimeout = Duration(seconds: 10);
  static const Duration _responseTimeout = Duration(seconds: 15);

  final String owner;
  final String repository;

  Future<GitHubRelease> fetchLatestRelease() async {
    final client = HttpClient()..connectionTimeout = _connectionTimeout;
    try {
      final request = await client.getUrl(
        Uri.https(
          'api.github.com',
          '/repos/$owner/$repository/releases/latest',
        ),
      );
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set('X-GitHub-Api-Version', '2022-11-28')
        ..set(HttpHeaders.userAgentHeader, 'Perfect-C2PA-Updater');

      final response = await request.close().timeout(_responseTimeout);
      final responseBody = await utf8.decoder
          .bind(response)
          .join()
          .timeout(_responseTimeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'GitHub returned HTTP ${response.statusCode}.',
          uri: request.uri,
        );
      }

      final json = jsonDecode(responseBody);
      if (json is! Map<String, dynamic>) {
        throw const FormatException('GitHub returned an invalid response.');
      }
      final tagName = json['tag_name'];
      final htmlUrl = json['html_url'];
      if (tagName is! String || htmlUrl is! String) {
        throw const FormatException('The GitHub Release is missing metadata.');
      }

      final pageUrl = Uri.tryParse(htmlUrl);
      if (pageUrl == null ||
          pageUrl.scheme != 'https' ||
          pageUrl.host != 'github.com') {
        throw const FormatException('The GitHub Release URL is invalid.');
      }
      return GitHubRelease(tagName: tagName, pageUrl: pageUrl);
    } finally {
      client.close(force: true);
    }
  }

  static bool isNewerVersion({
    required String currentVersion,
    required String releaseTag,
  }) {
    final current = _parseVersion(currentVersion);
    final release = _parseVersion(releaseTag);
    for (var index = 0; index < 3; index++) {
      if (release[index] != current[index]) {
        return release[index] > current[index];
      }
    }
    return false;
  }

  static List<int> _parseVersion(String value) {
    final normalized = value.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final match = RegExp(
      r'^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$',
    ).firstMatch(normalized);
    if (match == null) {
      throw FormatException('Invalid version: $value');
    }
    return <int>[
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    ];
  }
}
