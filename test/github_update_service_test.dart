import 'package:flutter_test/flutter_test.dart';

import 'package:c2pa_viewer/src/services/github_update_service.dart';

void main() {
  test('detects a newer GitHub release', () {
    expect(
      GitHubUpdateService.isNewerVersion(
        currentVersion: '1.0.0',
        releaseTag: 'v1.1.0',
      ),
      isTrue,
    );
    expect(
      GitHubUpdateService.isNewerVersion(
        currentVersion: '1.9.9',
        releaseTag: 'v2.0.0',
      ),
      isTrue,
    );
  });

  test('does not report the same or an older release as newer', () {
    expect(
      GitHubUpdateService.isNewerVersion(
        currentVersion: '1.0.0',
        releaseTag: 'v1.0.0',
      ),
      isFalse,
    );
    expect(
      GitHubUpdateService.isNewerVersion(
        currentVersion: '1.0.0',
        releaseTag: 'v0.9.9',
      ),
      isFalse,
    );
  });

  test('accepts build metadata in the local version', () {
    expect(
      GitHubUpdateService.isNewerVersion(
        currentVersion: '1.0.0+1',
        releaseTag: 'v1.0.1',
      ),
      isTrue,
    );
  });
}
