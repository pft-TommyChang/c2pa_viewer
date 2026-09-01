import 'dart:io';

import 'package:c2pa_viewer/src/models.dart';
import 'package:c2pa_viewer/src/services/github_update_service.dart';
import 'package:c2pa_viewer/src/screens/c2pa_browser_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  setUpAll(() {
    PackageInfo.setMockInitialValues(
      appName: 'Perfect C2PA',
      packageName: 'c2pa_viewer',
      version: '1.0.3',
      buildNumber: '103',
      buildSignature: '',
    );
  });

  testWidgets('viewer opens directly and inspects initial media', (
    WidgetTester tester,
  ) async {
    final tempDirectory = Directory.systemTemp.createTempSync(
      'c2pa_viewer_widget_test_',
    );
    addTearDown(() => tempDirectory.deleteSync(recursive: true));
    final sourceFile = File('${tempDirectory.path}/source.png');
    sourceFile.writeAsBytesSync(
      File('assets/app_icon_1024.png').readAsBytesSync(),
    );
    final inspectedPaths = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: C2paBrowserPage(
          pendingPaths: <String>[sourceFile.path],
          checkForUpdatesOnLaunch: false,
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(inspectedPaths, <String>[sourceFile.path]);
    expect(find.text('No Content Credentials'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('c2pa-file-location')),
      findsOneWidget,
    );
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey<String>('c2pa-file-location')))
          .dy,
      lessThan(tester.getTopLeft(find.byType(TabBar)).dy),
    );
    expect(find.text('source.png'), findsOneWidget);
    expect(find.text(sourceFile.path), findsOneWidget);
    final fullPathTooltip = find.descendant(
      of: find.byKey(const ValueKey<String>('c2pa-full-path')),
      matching: find.byType(Tooltip),
    );
    expect(fullPathTooltip, findsOneWidget);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(2400, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump();
    expect(fullPathTooltip, findsNothing);
    expect(
      find.byKey(const ValueKey<String>('c2pa-file-size')),
      findsOneWidget,
    );
    expect(find.text('v1.0.3 (103)'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('copy-media-path')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('reveal-media-file')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey<String>('copy-media-path')));
    await tester.pump();
    expect(find.text('Full path copied'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('open-media-file')),
      findsOneWidget,
    );
  });

  testWidgets('fit mode updates when the history viewport is resized', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final sourcePath = File('assets/app_icon_1024.png').absolute.path;
    const report = C2paReport(
      activeManifestLabel: 'active',
      manifests: <C2paManifest>[
        C2paManifest(label: 'active', title: 'source.png'),
      ],
      validationEntries: <C2paValidationEntry>[],
      rawJson: '{}',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: C2paBrowserPage(
          pendingPaths: <String>[sourcePath],
          checkForUpdatesOnLaunch: false,
          mediaLoader: (path) async => VideoClipInfo(
            path: path,
            name: 'source.png',
            duration: Duration.zero,
            width: 100,
            height: 100,
            hasAudio: false,
            mediaKind: MediaKind.photo,
            aiMetadata: const AiMediaMetadata(
              c2paStatus: C2paStatus.conformant,
              c2paReport: report,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    await tester.pump();

    InteractiveViewer historyViewer() => tester.widget<InteractiveViewer>(
      find.byKey(const ValueKey<String>('c2pa-history-viewer')),
    );
    final initialScale = historyViewer()
        .transformationController!
        .value
        .getMaxScaleOnAxis();

    tester.view.physicalSize = const Size(1200, 900);
    await tester.pump();
    await tester.pump();
    final resizedScale = historyViewer()
        .transformationController!
        .value
        .getMaxScaleOnAxis();

    expect(resizedScale, greaterThan(initialScale));

    MouseRegion panRegion() => tester.widget<MouseRegion>(
      find.byKey(const ValueKey<String>('c2pa-history-pan-region')),
    );
    expect(panRegion().cursor, SystemMouseCursors.grab);
    final gesture = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey<String>('c2pa-history-viewer')),
      ),
    );
    await tester.pump();
    expect(panRegion().cursor, SystemMouseCursors.grabbing);
    await gesture.up();
    await tester.pump();
    expect(panRegion().cursor, SystemMouseCursors.grab);
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
