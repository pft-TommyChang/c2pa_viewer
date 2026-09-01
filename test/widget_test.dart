import 'package:c2pa_viewer/src/models.dart';
import 'package:c2pa_viewer/src/services/github_update_service.dart';
import 'package:c2pa_viewer/src/screens/c2pa_browser_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('viewer opens directly and inspects initial media', (
    WidgetTester tester,
  ) async {
    final inspectedPaths = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: C2paBrowserPage(
          pendingPaths: const ['/tmp/source.png'],
          mediaLoader: (path) async {
            inspectedPaths.add(path);
            return VideoClipInfo(
              path: path,
              name: 'source.png',
              duration: Duration.zero,
              width: 100,
              height: 100,
              hasAudio: false,
              mediaKind: MediaKind.photo,
              aiMetadata: const AiMediaMetadata(c2paStatus: C2paStatus.absent),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(inspectedPaths, <String>['/tmp/source.png']);
    expect(find.text('No Content Credentials'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('open-media-file')),
      findsOneWidget,
    );
  });
  _updateTests();
}

// ---------------------------------------------------------------------------
// Fake update service for widget tests
// ---------------------------------------------------------------------------

class _FakeUpdateService extends GitHubUpdateService {
  const _FakeUpdateService({required this.fakeRelease})
      : super(owner: 'test', repository: 'test');

  final GitHubRelease fakeRelease;

  @override
  Future<GitHubRelease> fetchLatestRelease() async => fakeRelease;
}

// ---------------------------------------------------------------------------
// Update-indicator tests
// ---------------------------------------------------------------------------

void _updateTests() {
  testWidgets('shows update indicator when a newer release is available', (
    WidgetTester tester,
  ) async {
    final fakeRelease = GitHubRelease(
      tagName: 'v999.0.0',
      pageUrl: Uri.https('github.com', '/test/test/releases/tag/v999.0.0'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: C2paBrowserPage(
          mediaLoader: (_) async => throw UnimplementedError(),
          checkForUpdatesOnLaunch: true,
          updateService: _FakeUpdateService(fakeRelease: fakeRelease),
        ),
      ),
    );

    // Let the async update check complete.
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('update-available-indicator')),
      findsOneWidget,
    );
  });

  testWidgets('does not show update indicator when already on latest', (
    WidgetTester tester,
  ) async {
    final fakeRelease = GitHubRelease(
      tagName: 'v0.0.1',
      pageUrl: Uri.https('github.com', '/test/test/releases/tag/v0.0.1'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: C2paBrowserPage(
          mediaLoader: (_) async => throw UnimplementedError(),
          checkForUpdatesOnLaunch: true,
          updateService: _FakeUpdateService(fakeRelease: fakeRelease),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('update-available-indicator')),
      findsNothing,
    );
  });
}
