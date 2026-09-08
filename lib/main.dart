import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/screens/c2pa_browser_page.dart';
import 'src/services/ai_metadata_service.dart';
import 'src/services/media_inspection_service.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final initialPath = arguments
      .where((argument) => !argument.startsWith('--'))
      .firstOrNull;
  runApp(C2paViewerApp(initialPath: initialPath));
}

class C2paViewerApp extends StatelessWidget {
  const C2paViewerApp({super.key, this.initialPath});

  final String? initialPath;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFFF7A59),
      brightness: Brightness.light,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Perfect C2PA',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFFF3EFE7),
      ),
      home: _ViewerHome(initialPath: initialPath),
    );
  }
}

class _ViewerHome extends StatefulWidget {
  const _ViewerHome({this.initialPath});

  final String? initialPath;

  @override
  State<_ViewerHome> createState() => _ViewerHomeState();
}

class _ViewerHomeState extends State<_ViewerHome> {
  static const MethodChannel _startupChannel = MethodChannel(
    'c2pa_viewer/startup',
  );
  static const MethodChannel _mediaOpenChannel = MethodChannel(
    'c2pa_viewer/media_open',
  );

  final MediaInspectionService _inspectionService =
      const MediaInspectionService();
  List<String> _pendingPaths = [];
  int _openGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_dismissNativeStartupView());
    });
    _pendingPaths = (widget.initialPath?.isNotEmpty ?? false)
        ? [widget.initialPath!]
        : [];
    _mediaOpenChannel.setMethodCallHandler(_handleMediaOpenMethodCall);
    unawaited(_consumePendingMediaFilesWithRetry());
    if (!Platform.isIOS && !Platform.isAndroid) {
      unawaited(
        _inspectionService.aiMetadataService.refreshTrustListIfNeeded(),
      );
    }
  }

  @override
  void dispose() {
    _mediaOpenChannel.setMethodCallHandler(null);
    AiMetadataService.cleanupExtractedResources();
    super.dispose();
  }

  Future<void> _dismissNativeStartupView() async {
    try {
      await _startupChannel.invokeMethod<void>('dismiss');
    } on MissingPluginException {
      // Only the macOS runner installs this native startup view.
    }
  }

  Future<Object?> _handleMediaOpenMethodCall(MethodCall call) async {
    if (call.method != 'mediaFilesOpened') {
      throw MissingPluginException('Unknown method ${call.method}');
    }

    // Native sends the paths with the notification. This avoids depending on
    // the timing of a second channel call while the app is being foregrounded.
    final directPaths = call.arguments is List
        ? (call.arguments as List)
              .whereType<String>()
              .where((path) => path.isNotEmpty)
              .toList()
        : const <String>[];
    if (directPaths.isNotEmpty) {
      _acceptPendingPaths(directPaths);
      // Read the native queue as well. The direct event is the source of
      // truth; this read covers cold-start races where the event was missed.
      await _consumePendingMediaFilesWithRetry();
      return null;
    }

    await _consumePendingMediaFilesWithRetry();
    return null;
  }

  void _acceptPendingPaths(List<String> paths) {
    if (!mounted || paths.isEmpty) return;
    final uniquePaths = <String>[];
    for (final path in paths) {
      if (!uniquePaths.contains(path)) uniquePaths.add(path);
    }
    if (listEquals(uniquePaths, _pendingPaths)) return;
    setState(() {
      _pendingPaths = uniquePaths;
      _openGeneration++;
    });
  }

  Future<void> _consumePendingMediaFilesWithRetry({
    int retriesRemaining = 10,
  }) async {
    try {
      final paths = await _mediaOpenChannel.invokeListMethod<String>(
        'consumePendingMediaFiles',
      );
      final valid = paths?.where((p) => p.isNotEmpty).toList() ?? [];
      _acceptPendingPaths(valid);
    } on MissingPluginException {
      // The implicit Flutter engine can finish booting just after initState.
      // Retry briefly so a native handoff is not lost during that window.
      if (retriesRemaining > 0 && mounted) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await _consumePendingMediaFilesWithRetry(
          retriesRemaining: retriesRemaining - 1,
        );
      }
    } catch (error, stackTrace) {
      debugPrint('[MediaOpen] Flutter consume failed: $error');
      debugPrint('$stackTrace');
    }
  }

  @override
  Widget build(BuildContext context) {
    return C2paBrowserPage(
      // Recreate the browser for each native handoff so the incoming file is
      // handled by initState after the new page is mounted.
      key: ValueKey<String>('c2pa-browser-$_openGeneration'),
      pendingPaths: _pendingPaths,
      openGeneration: _openGeneration,
      mediaLoader: _inspectionService.inspect,
    );
  }
}
