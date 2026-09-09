import 'dart:io';

import 'package:c2pa_viewer/src/models.dart';
import 'package:c2pa_viewer/src/services/c2pa_test_sign_service.dart';
import 'package:c2pa_viewer/src/services/c2pa_write_options_store.dart';
import 'package:c2pa_viewer/src/services/github_update_service.dart';
import 'package:c2pa_viewer/src/screens/c2pa_browser_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

class _MemoryC2paWriteOptionsStore implements C2paWriteOptionsStore {
  _MemoryC2paWriteOptionsStore(this.options);

  C2paWriteOptions options;
  int saveCount = 0;

  @override
  Future<C2paWriteOptions> load() async => options;

  @override
  Future<void> save(C2paWriteOptions options) async {
    this.options = options;
    saveCount++;
  }
}

void main() {
  setUpAll(() {
    PackageInfo.setMockInitialValues(
      appName: 'Perfect C2PA',
      packageName: 'c2pa_viewer',
      version: '1.0.4',
      buildNumber: '104',
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
    final signedPaths = <String>[];
    final signedOutputPath = '${tempDirectory.path}/source_test_signed.png';
    final writeOptionsStore = _MemoryC2paWriteOptionsStore(
      const C2paWriteOptions(mode: C2paWriteMode.add, createNewFile: true),
    );
    var destinationPickerCalls = 0;
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
          testWriter: (clip, outputPath, mode) async {
            signedPaths.add('${mode.name}: ${clip.path} -> $outputPath');
          },
          testSignDestinationPicker: (_, _) async {
            destinationPickerCalls++;
            return signedOutputPath;
          },
          writeOptionsStore: writeOptionsStore,
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
      greaterThan(tester.getTopLeft(find.byType(TabBar)).dy),
    );
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey<String>('c2pa-file-location')))
          .dy -
          tester.getBottomLeft(find.byType(TabBar)).dy,
      7,
    );
    expect(
      tester
          .getTopLeft(
            find.byKey(const ValueKey<String>('c2pa-no-cred-preview')),
          )
          .dy -
          tester
              .getBottomLeft(
                find.byKey(const ValueKey<String>('c2pa-file-location')),
              )
              .dy,
      7,
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
    expect(find.text('v1.0.4 (104)'), findsOneWidget);
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
    final testSignButton = find.byKey(
      const ValueKey<String>('test-sign-media'),
    );
    expect(testSignButton, findsOneWidget);
    expect(
      tester.getTopLeft(testSignButton).dx,
      lessThan(tester.getTopLeft(find.byTooltip('Previous file')).dx),
    );
    await tester.tap(testSignButton);
    await tester.pumpAndSettle();
    expect(find.text('C2PA write test'), findsOneWidget);
    expect(find.text('Add C2PA'), findsOneWidget);
    expect(find.text('Replace C2PA'), findsOneWidget);
    expect(find.text('Remove C2PA'), findsOneWidget);
    expect(find.text('Create new file'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('run-c2pa-write-test')));
    await tester.pumpAndSettle();
    expect(signedPaths, <String>[
      'add: ${sourceFile.path} -> $signedOutputPath',
    ]);
    expect(inspectedPaths, <String>[sourceFile.path, signedOutputPath]);
    expect(destinationPickerCalls, 1);

    await tester.tap(testSignButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('c2pa-write-remove')));
    await tester.tap(
      find.byKey(const ValueKey<String>('c2pa-create-new-file')),
    );
    await tester.tap(find.byKey(const ValueKey<String>('run-c2pa-write-test')));
    await tester.pumpAndSettle();
    expect(signedPaths.last, 'remove: $signedOutputPath -> $signedOutputPath');
    expect(destinationPickerCalls, 1);
    expect(inspectedPaths.last, signedOutputPath);
    expect(writeOptionsStore.options.mode, C2paWriteMode.remove);
    expect(writeOptionsStore.options.createNewFile, isFalse);
    expect(writeOptionsStore.saveCount, 2);

    await tester.tap(testSignButton);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<RadioGroup<C2paWriteMode>>(
            find.byType(RadioGroup<C2paWriteMode>),
          )
          .groupValue,
      C2paWriteMode.remove,
    );
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey<String>('c2pa-create-new-file')),
          )
          .value,
      isFalse,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
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
    await tester.tap(find.byType(Tab).at(1));
    await tester.pumpAndSettle();
    await tester.pump();

    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey<String>('c2pa-history-panel')))
          .dy -
          tester
              .getBottomLeft(
                find.byKey(const ValueKey<String>('c2pa-file-location')),
              )
              .dy,
      7,
    );

    InteractiveViewer historyViewer() => tester.widget<InteractiveViewer>(
      find.byKey(const ValueKey<String>('c2pa-history-viewer')),
    );
    final initialScale = historyViewer().transformationController!.value
        .getMaxScaleOnAxis();

    tester.view.physicalSize = const Size(1200, 900);
    await tester.pump();
    await tester.pump();
    final resizedScale = historyViewer().transformationController!.value
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
    await tester.pump(const Duration(milliseconds: 50));
    expect(panRegion().cursor, SystemMouseCursors.grab);
  });

  testWidgets('opens media delivered after the initial build', (
    WidgetTester tester,
  ) async {
    const sourcePath = '/tmp/shared-media.png';
    final inspectedPaths = <String>[];

    Widget buildViewer({
      required List<String> pendingPaths,
      required int generation,
    }) {
      return MaterialApp(
        home: C2paBrowserPage(
          key: const ValueKey<String>('shared-media-viewer'),
          pendingPaths: pendingPaths,
          openGeneration: generation,
          checkForUpdatesOnLaunch: false,
          mediaLoader: (path) async {
            inspectedPaths.add(path);
            return VideoClipInfo(
              path: path,
              name: 'shared-media.png',
              duration: Duration.zero,
              width: 100,
              height: 100,
              hasAudio: false,
              mediaKind: MediaKind.photo,
              aiMetadata: const AiMediaMetadata(c2paStatus: C2paStatus.absent),
            );
          },
        ),
      );
    }

    await tester.pumpWidget(
      buildViewer(pendingPaths: const <String>[], generation: 0),
    );
    await tester.pump();
    await tester.pumpWidget(
      buildViewer(pendingPaths: const <String>[sourcePath], generation: 1),
    );
    await tester.pumpAndSettle();

    expect(inspectedPaths, <String>[sourcePath]);
    expect(find.text('No Content Credentials'), findsOneWidget);
  });

  testWidgets('shows C2PA signer and manifest metadata', (tester) async {
    final sourcePath = File('assets/app_icon_1024.png').absolute.path;
    const report = C2paReport(
      activeManifestLabel: 'active',
      manifests: <C2paManifest>[
        C2paManifest(
          label: 'active',
          title: 'source.png',
          issuer: 'Byteplus Pte. Ltd.',
          commonName: 'certificate@byteplus.com',
          algorithm: 'PS256',
          claimVersion: 'v2',
          contentType: 'AI-generated',
          software: 'BytePlus ModelArk',
        ),
      ],
      validationEntries: <C2paValidationEntry>[],
      rawJson: '{}',
    );

    await tester.pumpWidget(MaterialApp(
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
    ));
    await tester.pumpAndSettle();

    for (final text in <String>[
      'Signer',
      'certificate@byteplus.com',
      'Software',
      'BytePlus ModelArk',
      'Claim Version',
      'Content type',
      'AI-generated',
    ]) {
      expect(find.textContaining(text, findRichText: true), findsAtLeastNWidgets(1));
    }
    expect(find.textContaining('App or device', findRichText: true), findsNothing);
  });

  testWidgets('opens search with the raw JSON header in view', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final sourcePath = File('assets/app_icon_1024.png').absolute.path;
    final rawJson = List<String>.generate(
      120,
      (index) =>
          '  "entry$index": "${index == 40 || index == 100 ? 'nu-match' : index}"',
    ).join('\n');
    final report = C2paReport(
      activeManifestLabel: 'active',
      manifests: const <C2paManifest>[
        C2paManifest(label: 'active', title: 'source.png'),
      ],
      validationEntries: List<C2paValidationEntry>.generate(
        10,
        (index) => C2paValidationEntry(
          code: 'check.$index',
          outcome: C2paValidationOutcome.passed,
          explanation: 'check passed',
        ),
      ),
      rawJson: '{\n$rawJson\n}',
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
            aiMetadata: AiMediaMetadata(
              c2paStatus: C2paStatus.conformant,
              c2paReport: report,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tabBar = find.byType(TabBar);
    final tabController = tester.widget<TabBar>(tabBar).controller!;
    expect(tabController.index, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(tabController.index, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(tabController.index, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(tabController.index, 1);

    await tester.tap(find.byType(Tab).at(2));
    await tester.pumpAndSettle();

    expect(find.text('Tree'), findsOneWidget);
    expect(find.text('Raw'), findsOneWidget);
    expect(find.text('Tree view'), findsNothing);
    expect(find.text('Raw JSON'), findsNothing);
    expect(
      tester.getCenter(find.text('Raw')).dx,
      lessThan(tester.getCenter(find.text('Tree')).dx),
    );
    expect(
      tester
          .getRect(find.byKey(const ValueKey<String>('c2pa-json-view-mode')))
          .height,
      lessThan(32),
    );

    final scrollable = find.byType(Scrollable).at(1);
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final rawHeader = find.text('Manifest');
    expect(rawHeader, findsOneWidget);
    final headerTop = tester.getTopLeft(rawHeader).dy;
    expect(headerTop, greaterThan(420));
    expect(headerTop, lessThan(550));
    expect(
      find.byKey(const ValueKey<String>('c2pa-search-field')),
      findsOneWidget,
    );

    final headerOffset = tester
        .state<ScrollableState>(scrollable)
        .position
        .pixels;
    await tester.enterText(
      find.byKey(const ValueKey<String>('c2pa-search-field')),
      'nu',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final firstMatchOffset =
        tester.state<ScrollableState>(scrollable).position.pixels;
    expect(firstMatchOffset, greaterThan(headerOffset));

    await tester.tap(find.byTooltip('Next match'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final secondMatchOffset =
        tester.state<ScrollableState>(scrollable).position.pixels;
    expect(secondMatchOffset, greaterThan(firstMatchOffset));

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.state<ScrollableState>(scrollable).position.pixels,
      lessThan(secondMatchOffset),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('c2pa-search-field')),
      findsNothing,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('c2pa-search-field')),
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
