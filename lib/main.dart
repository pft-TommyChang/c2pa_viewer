import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/screens/c2pa_browser_page.dart';
import 'src/services/ai_metadata_service.dart';
import 'src/services/media_inspection_service.dart';

void main(List<String> arguments) {
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
    _pendingPaths = (widget.initialPath?.isNotEmpty ?? false)
        ? [widget.initialPath!]
        : [];
    _mediaOpenChannel.setMethodCallHandler(_handleMediaOpenMethodCall);
    unawaited(_consumePendingMediaFiles());
    unawaited(_inspectionService.aiMetadataService.refreshTrustListIfNeeded());
  }

  @override
  void dispose() {
    _mediaOpenChannel.setMethodCallHandler(null);
    AiMetadataService.cleanupExtractedResources();
    super.dispose();
  }

  Future<Object?> _handleMediaOpenMethodCall(MethodCall call) async {
    if (call.method != 'mediaFilesOpened') {
      throw MissingPluginException('Unknown method ${call.method}');
    }
    await _consumePendingMediaFiles();
    return null;
  }

  Future<void> _consumePendingMediaFiles() async {
    try {
      final paths = await _mediaOpenChannel.invokeListMethod<String>(
        'consumePendingMediaFiles',
      );
      final valid = paths?.where((p) => p.isNotEmpty).toList() ?? [];
      if (mounted && valid.isNotEmpty) {
        setState(() {
          _pendingPaths = valid;
          _openGeneration++;
        });
      }
    } on MissingPluginException {
      // Tests and non-macOS runners do not install the native channel.
    }
  }

  @override
  Widget build(BuildContext context) {
    return C2paBrowserPage(
      key: const Key('c2pa-browser'),
      pendingPaths: _pendingPaths,
      openGeneration: _openGeneration,
      mediaLoader: _inspectionService.inspect,
      onClose: () => exit(0),
    );
  }
}
