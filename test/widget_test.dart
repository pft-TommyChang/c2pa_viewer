import 'package:c2pa_viewer/src/models.dart';
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
          initialPath: '/tmp/source.png',
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
}
