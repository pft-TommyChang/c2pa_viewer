import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import '../services/media_inspection_service.dart' show MediaInspectionService;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

import '../models.dart';

const Set<String> _supportedVideoExtensions = <String>{
  '.mp4',
  '.mov',
  '.m4v',
  '.avi',
  '.mkv',
  '.webm',
};
const Set<String> _supportedPhotoExtensions = <String>{
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.heic',
  '.heif',
};

const Color _c2paPageBackground = Color(0xFFFFFCF7);
const Color _c2paPanelBackground = Color(0xFFF3EFE7);
const Color _c2paCardBorder = Color(0xFFD8D0C4);
const Color _c2paMutedText = Color(0xFF697180);
const Color _c2paAccent = Color(0xFFFF7A59);
const Color _c2paAccentDark = Color(0xFFD95C3E);
const double _c2paTreeCardWidth = 234;
const double _c2paTreeCardHeight = 274;
const double _c2paTreeLevelGap = 48;

VideoClipInfo _emptyC2paClip() => const VideoClipInfo(
  path: '',
  name: '',
  duration: Duration.zero,
  width: 0,
  height: 0,
  hasAudio: false,
  mediaKind: MediaKind.photo,
);

typedef C2paMediaLoader = Future<VideoClipInfo> Function(String path);

class C2paBrowserPage extends StatefulWidget {
  const C2paBrowserPage({
    super.key,
    required this.mediaLoader,
    this.pendingPaths = const [],
    this.openGeneration = 0,
    this.onClose,
  });

  final C2paMediaLoader mediaLoader;
  final List<String> pendingPaths;
  final int openGeneration;
  final VoidCallback? onClose;

  @override
  State<C2paBrowserPage> createState() => _C2paBrowserPageState();
}

class _C2paBrowserPageState extends State<C2paBrowserPage> {
  late VideoClipInfo _clip;
  late VideoPlayerController? _controller;
  bool _isDragging = false;
  bool _isParsing = false;
  bool _hasMedia = false;
  int _parseGeneration = 0;
  final List<String> _history = [];
  int _historyIndex = -1;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _clip = _emptyC2paClip();
    _controller = null;
    if (widget.pendingPaths.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_openPendingPaths(widget.pendingPaths));
      });
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(C2paBrowserPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.openGeneration != oldWidget.openGeneration &&
        widget.pendingPaths.isNotEmpty) {
      unawaited(_openPendingPaths(widget.pendingPaths));
    }
  }

  bool _isSupportedMediaPath(String path) {
    final extension = p.extension(path).toLowerCase();
    return _supportedVideoExtensions.contains(extension) ||
        _supportedPhotoExtensions.contains(extension);
  }

  void _showErrorToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const ValueKey<String>('c2pa-error-toast'),
          behavior: SnackBarBehavior.floating,
          content: Text(message),
        ),
      );
  }

  Future<void> _handleDrop(List<DropItem> items) async {
    final paths = items
        .where((item) => item is! DropItemDirectory)
        .map((item) => item.path)
        .where(_isSupportedMediaPath)
        .toList();
    setState(() => _isDragging = false);
    if (paths.isEmpty) {
      _showErrorToast('No supported media file was dropped.');
      return;
    }
    await _openPendingPaths(paths);
  }

  // Open a batch of paths (from Finder 'Open With' or drag-and-drop).
  // Appends all valid paths to history and navigates to the first.
  Future<void> _openPendingPaths(List<String> paths) async {
    final valid = paths.where(_isSupportedMediaPath).toList();
    if (valid.isEmpty) return;
    if (_historyIndex < _history.length - 1) {
      _history.removeRange(_historyIndex + 1, _history.length);
    }
    _history.addAll(valid);
    _historyIndex = _history.length - valid.length;
    await _inspectPath(valid.first, addToHistory: false);
  }

  Future<void> _pickMedia() async {
    final file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: 'Photos and videos',
          extensions: <String>[
            'mp4',
            'mov',
            'm4v',
            'avi',
            'mkv',
            'webm',
            'jpg',
            'jpeg',
            'png',
            'webp',
            'heic',
            'heif',
          ],
        ),
      ],
    );
    if (file != null) await _inspectPath(file.path);
  }

  // Push path onto history, truncating any forward entries.
  void _pushPath(String path) {
    if (_historyIndex < _history.length - 1) {
      _history.removeRange(_historyIndex + 1, _history.length);
    }
    _history.add(path);
    _historyIndex = _history.length - 1;
  }

  bool get _canGoPrev => _historyIndex > 0 && !_isParsing;
  bool get _canGoNext => _historyIndex < _history.length - 1 && !_isParsing;

  Future<void> _navigatePrev() async {
    if (!_canGoPrev) return;
    _historyIndex--;
    await _inspectPath(_history[_historyIndex], addToHistory: false);
  }

  Future<void> _navigateNext() async {
    if (!_canGoNext) return;
    _historyIndex++;
    await _inspectPath(_history[_historyIndex], addToHistory: false);
  }

  Future<void> _inspectPath(String path, {bool addToHistory = true}) async {
    if (!_isSupportedMediaPath(path)) {
      _showErrorToast('No supported media file was provided.');
      return;
    }
    if (addToHistory) _pushPath(path);
    final generation = ++_parseGeneration;
    setState(() => _isParsing = true);
    try {
      final clip = await widget.mediaLoader(path);
      if (!mounted || generation != _parseGeneration) return;
      setState(() {
        _clip = clip;
        _hasMedia = true;
        _controller = null;
        _isParsing = false;
      });
    } catch (error) {
      if (!mounted || generation != _parseGeneration) return;
      setState(() => _isParsing = false);
      _showErrorToast('Unable to inspect ${p.basename(path)}: $error');
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft && _canGoPrev) {
      unawaited(_navigatePrev());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight && _canGoNext) {
      unawaited(_navigateNext());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final report = _clip.aiMetadata.c2paReport;
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
      key: const ValueKey<String>('c2pa-page-content'),
      backgroundColor: _c2paPageBackground,
      body: SafeArea(
        child: DropTarget(
          onDragEntered: (_) => setState(() => _isDragging = true),
          onDragExited: (_) => setState(() => _isDragging = false),
          onDragDone: (details) => unawaited(_handleDrop(details.files)),
          child: DefaultTabController(
            length: 3,
            child: Stack(
              children: <Widget>[
                Column(
                  children: <Widget>[
                    _C2paPageHeader(
                      clip: _hasMedia ? _clip : null,
                      onOpen: () => unawaited(_pickMedia()),
                      onClose:
                          widget.onClose ?? () => Navigator.of(context).pop(),
                      onPrev: () => unawaited(_navigatePrev()),
                      onNext: () => unawaited(_navigateNext()),
                      canGoPrev: _canGoPrev,
                      canGoNext: _canGoNext,
                    ),
                    // Tab bar: always shown when media loaded;
                    // disabled (dimmed, non-interactive) when no C2PA report.
                    if (_hasMedia)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
                        child: IgnorePointer(
                          ignoring: report == null,
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 200),
                            opacity: report == null ? 0.35 : 1.0,
                            child: Material(
                              color: _c2paPanelBackground,
                              borderRadius: BorderRadius.circular(14),
                              clipBehavior: Clip.antiAlias,
                              child: const SizedBox(
                                height: 44,
                                child: TabBar(
                                  dividerColor: Colors.transparent,
                                  indicator: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.all(
                                      Radius.circular(10),
                                    ),
                                  ),
                                  indicatorPadding: EdgeInsets.all(4),
                                  indicatorSize: TabBarIndicatorSize.tab,
                                  splashBorderRadius: BorderRadius.all(
                                    Radius.circular(10),
                                  ),
                                  labelColor: Color(0xFF171A21),
                                  unselectedLabelColor: _c2paMutedText,
                                  labelStyle: TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                  tabs: <Widget>[
                                    _C2paTab(
                                      icon: Icons.badge_outlined,
                                      label: 'Overview',
                                    ),
                                    _C2paTab(
                                      icon: Icons.account_tree_outlined,
                                      label: 'History',
                                    ),
                                    _C2paTab(
                                      icon: Icons.fact_check_outlined,
                                      label: 'Checks & JSON',
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    Expanded(
                      child: report != null
                          ? TabBarView(
                              children: <Widget>[
                                _C2paOverview(
                                  clip: _clip,
                                  report: report,
                                  controller: _controller,
                                ),
                                _C2paHistoryTree(clip: _clip, report: report),
                                _C2paTechnicalView(report: report),
                              ],
                            )
                          : !_hasMedia
                          ? const _C2paAwaitingMediaView()
                          : _clip.aiMetadata.c2paStatus == C2paStatus.absent
                          ? _C2paNoCredentialsView(clip: _clip)
                          : _C2paUnavailableView(clip: _clip),
                    ),
                  ],
                ),
                IgnorePointer(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 140),
                    opacity: _isDragging ? 1 : 0,
                    child: Container(
                      key: const ValueKey<String>('c2pa-drop-hover'),
                      margin: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: _c2paAccent.withValues(alpha: 0.12),
                        border: Border.all(color: _c2paAccent, width: 3),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      alignment: Alignment.center,
                      child: const _C2paDropPrompt(prominent: true),
                    ),
                  ),
                ),
                // Thin progress bar while switching files (old content stays visible)
                if (_isParsing && _hasMedia)
                  const Positioned(
                    top: 0, left: 0, right: 0,
                    child: LinearProgressIndicator(
                      key: ValueKey<String>('c2pa-nav-progress'),
                      minHeight: 2,
                    ),
                  ),
                // Full overlay with spinner only on the very first load
                if (_isParsing && !_hasMedia)
                  const Positioned.fill(
                    child: ColoredBox(
                      key: ValueKey<String>('c2pa-parsing-overlay'),
                      color: Color(0xAAFFFCF7),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            CircularProgressIndicator(),
                            SizedBox(height: 14),
                            Text('Inspecting Content Credentials…'),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
    );
  }
}

class _C2paTab extends StatelessWidget {
  const _C2paTab({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 17),
          const SizedBox(width: 7),
          Text(label),
        ],
      ),
    );
  }
}

class _C2paPageHeader extends StatelessWidget {
  const _C2paPageHeader({
    required this.clip,
    required this.onOpen,
    required this.onClose,
    required this.onPrev,
    required this.onNext,
    required this.canGoPrev,
    required this.canGoNext,
  });

  final VideoClipInfo? clip;
  final VoidCallback onOpen;
  final VoidCallback onClose;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final bool canGoPrev;
  final bool canGoNext;

  @override
  Widget build(BuildContext context) {
    final status = clip?.aiMetadata.c2paStatus;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 10, 11),
      child: Row(
        children: <Widget>[
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: const Color(0xFFFFE7DF),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.verified_user_outlined,
              color: _c2paAccentDark,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Content Credentials',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (clip == null)
                  Text(
                    'Drop a media file anywhere on this page',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: _c2paMutedText),
                  )
                else
                  Row(
                    children: <Widget>[
                      Tooltip(
                        message: 'Reveal in Finder',
                        child: GestureDetector(
                          onTap: () => Process.run('open', <String>['-R', clip!.path]),
                          child: Icon(
                            Icons.folder_outlined,
                            size: 14,
                            color: _c2paMutedText,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Tooltip(
                          message: clip!.path,
                          child: Text(
                            p.basename(clip!.path),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(color: _c2paMutedText),
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          if (status != null) _C2paStatusPill(status: status),
          const SizedBox(width: 6),
          IconButton(
            tooltip: 'Previous file',
            onPressed: canGoPrev ? onPrev : null,
            icon: const Icon(Icons.chevron_left),
          ),
          IconButton(
            tooltip: 'Next file',
            onPressed: canGoNext ? onNext : null,
            icon: const Icon(Icons.chevron_right),
          ),
          IconButton(
            key: const ValueKey<String>('open-media-file'),
            tooltip: 'Open media',
            onPressed: onOpen,
            icon: const Icon(Icons.folder_open_outlined),
          ),
          IconButton(
            key: const ValueKey<String>('close-c2pa-browser'),
            tooltip: 'Close',
            onPressed: onClose,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

class _C2paDropPrompt extends StatelessWidget {
  const _C2paDropPrompt({this.prominent = false});

  final bool prominent;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _c2paPageBackground.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(16),
        boxShadow: prominent
            ? const <BoxShadow>[
                BoxShadow(color: Color(0x22000000), blurRadius: 18),
              ]
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.file_download_outlined,
              size: prominent ? 44 : 36,
              color: _c2paAccentDark,
            ),
            const SizedBox(height: 10),
            Text(
              'Drop media to inspect Content Credentials',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),

          ],
        ),
      ),
    );
  }
}

class _C2paAwaitingMediaView extends StatelessWidget {
  const _C2paAwaitingMediaView();

  @override
  Widget build(BuildContext context) {
    return const Center(child: _C2paDropPrompt());
  }
}

class _C2paNoCredentialsView extends StatelessWidget {
  const _C2paNoCredentialsView({required this.clip});

  final VideoClipInfo clip;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: <Widget>[
        SizedBox(
          height: 206,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              AspectRatio(
                aspectRatio: 1.0,
                child: _C2paPreviewCard(
                  key: const ValueKey<String>('c2pa-no-cred-preview'),
                  clip: clip,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: _c2paCardBorder),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          const Icon(
                            Icons.gpp_maybe_outlined,
                            size: 19,
                            color: _c2paMutedText,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'No Content Credentials',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '${p.basename(clip.path)} does not contain C2PA data.',
                        style: const TextStyle(
                          color: _c2paMutedText,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Center(child: _C2paDropPrompt()),
      ],
    );
  }
}

class _C2paStatusPill extends StatelessWidget {
  const _C2paStatusPill({required this.status});

  final C2paStatus status;

  @override
  Widget build(BuildContext context) {
    final color = _c2paStatusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.circle, size: 8, color: color),
          const SizedBox(width: 5),
          Text(
            _c2paStatusLabel(status),
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _C2paUnavailableView extends StatelessWidget {
  const _C2paUnavailableView({required this.clip});

  final VideoClipInfo clip;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.inventory_2_outlined,
                size: 48,
                color: Color(0xFF697180),
              ),
              const SizedBox(height: 14),
              Text(
                'Detailed manifest unavailable',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(
                'The credential status was detected, but this item was loaded before the full C2PA report was retained. Reload the media to inspect its history.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _C2paOverview extends StatelessWidget {
  const _C2paOverview({
    required this.clip,
    required this.report,
    this.controller,
  });

  final VideoClipInfo clip;
  final C2paReport report;
  final VideoPlayerController? controller;

  @override
  Widget build(BuildContext context) {
    final manifest = report.activeManifest;
    return ListView(
      padding: const EdgeInsets.all(18),
      children: <Widget>[
        SizedBox(
          height: 206,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              AspectRatio(
                aspectRatio: 1.0,
                child: _C2paPreviewCard(
                  key: const ValueKey<String>('c2pa-overview-preview'),
                  clip: clip,
                  controller: controller,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _C2paInfoCard(
                  key: const ValueKey<String>('c2pa-overview-signer'),
                  title: 'Signer',
                  icon: Icons.draw_outlined,
                  rows: <(String, String?)>[
                    ('Issuer', manifest?.issuer ?? manifest?.commonName),
                    ('Algorithm', manifest?.algorithm),
                    ('Signed', manifest?.signedAt),
                    ('App or device', manifest?.claimGenerator),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _C2paInfoCard(
                  key: const ValueKey<String>('c2pa-overview-manifest'),
                  title: 'Manifest',
                  icon: Icons.description_outlined,
                  rows: <(String, String?)>[
                    ('Title', manifest?.title ?? p.basename(clip.path)),
                    (
                      'Format',
                      manifest?.format ??
                          shortMediaTypeLabel(clip.path, clip.mediaKind),
                    ),
                    (
                      'History',
                      '${report.manifests.length} manifest${report.manifests.length == 1 ? '' : 's'}',
                    ),
                    (
                      'Validation',
                      '${report.passedCheckCount} passed · ${report.failedCheckCount} failed',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Text(
          'Activity',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        if (manifest == null || manifest.actions.isEmpty)
          const _C2paEmptyCard(
            message: 'No declared actions in the active manifest.',
          )
        else
          ...manifest.actions.indexed.map(
            (entry) => _C2paActionTile(index: entry.$1, action: entry.$2),
          ),
      ],
    );
  }
}

class _C2paPreviewCard extends StatefulWidget {
  const _C2paPreviewCard({
    super.key,
    required this.clip,
    this.controller,
  });

  final VideoClipInfo clip;
  final VideoPlayerController? controller;

  @override
  State<_C2paPreviewCard> createState() => _C2paPreviewCardState();
}

class _C2paPreviewCardState extends State<_C2paPreviewCard> {
  Future<Uint8List?>? _thumbnailFuture;

  @override
  void initState() {
    super.initState();
    if (!widget.clip.isPhoto) {
      _thumbnailFuture = MediaInspectionService.thumbnail(widget.clip.path);
    }
  }

  @override
  void didUpdateWidget(_C2paPreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clip.path != widget.clip.path) {
      _thumbnailFuture = widget.clip.isPhoto
          ? null
          : MediaInspectionService.thumbnail(widget.clip.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final clip = widget.clip;
    final controller = widget.controller;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFF171A21),
        borderRadius: BorderRadius.circular(18),
      ),
      child: clip.isPhoto
          ? Image.file(
              File(clip.path),
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Icon(
                Icons.image_not_supported_outlined,
                color: Colors.white54,
              ),
            )
          : controller != null && controller.value.isInitialized
          ? Stack(
              fit: StackFit.expand,
              children: <Widget>[
                ColoredBox(
                  color: const Color(0xFF171A21),
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: controller.value.aspectRatio > 0
                          ? controller.value.aspectRatio
                          : clip.width > 0 && clip.height > 0
                          ? clip.width / clip.height
                          : 16 / 9,
                      child: VideoPlayer(controller),
                    ),
                  ),
                ),
              ],
            )
          : FutureBuilder<Uint8List?>(
              future: _thumbnailFuture,
              builder: (context, snapshot) {
                final data = snapshot.data;
                if (data != null) {
                  return Image.memory(data, fit: BoxFit.contain);
                }
                return const Center(
                  child: Icon(
                    Icons.movie_outlined,
                    size: 56,
                    color: Colors.white54,
                  ),
                );
              },
            ),
    );
  }
}

class _C2paInfoCard extends StatelessWidget {
  const _C2paInfoCard({
    super.key,
    required this.title,
    required this.icon,
    required this.rows,
  });

  final String title;
  final IconData icon;
  final List<(String, String?)> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _c2paCardBorder),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 19, color: _c2paAccentDark),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 240;
                return Column(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: rows
                      .where((row) => row.$2 != null)
                      .map(
                        (row) => compact
                            ? Align(
                                alignment: Alignment.centerLeft,
                                child: Text.rich(
                                  TextSpan(
                                    children: <InlineSpan>[
                                      TextSpan(
                                        text: '${row.$1}: ',
                                        style: const TextStyle(
                                          color: _c2paMutedText,
                                          fontSize: 11,
                                        ),
                                      ),
                                      TextSpan(text: row.$2!),
                                    ],
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              )
                            : Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  SizedBox(
                                    width: 94,
                                    child: Text(
                                      row.$1,
                                      style: const TextStyle(
                                        color: _c2paMutedText,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      row.$2!,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                      )
                      .toList(growable: false),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _C2paActionTile extends StatelessWidget {
  const _C2paActionTile({required this.index, required this.action});

  final int index;
  final C2paAction action;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 34,
          child: Column(
            children: <Widget>[
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: Color(0xFFFFE7DF),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(
                    color: _c2paAccentDark,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                  ),
                ),
              ),
              Container(width: 1, height: 48, color: _c2paCardBorder),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 14),
            child: ListTile(
              tileColor: Colors.white,
              shape: RoundedRectangleBorder(
                side: const BorderSide(color: _c2paCardBorder),
                borderRadius: BorderRadius.circular(12),
              ),
              title: Text(
                _friendlyC2paAction(action.action),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                <String>[
                  if (action.softwareAgent != null) action.softwareAgent!,
                  if (action.digitalSourceType != null)
                    _shortC2paValue(action.digitalSourceType!),
                ].join(' · '),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _C2paHistoryTree extends StatefulWidget {
  const _C2paHistoryTree({required this.clip, required this.report});

  final VideoClipInfo clip;
  final C2paReport report;

  @override
  State<_C2paHistoryTree> createState() => _C2paHistoryTreeState();
}

class _C2paHistoryTreeState extends State<_C2paHistoryTree> {
  final ScrollController _horizontalController = ScrollController();
  final ScrollController _verticalController = ScrollController();

  @override
  void dispose() {
    _horizontalController.dispose();
    _verticalController.dispose();
    super.dispose();
  }

  void _scrollBy(ScrollController controller, double delta) {
    if (!controller.hasClients || delta == 0) return;
    final position = controller.position;
    controller.jumpTo(
      (position.pixels + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  void _handlePointerSignal(PointerSignalEvent signal) {
    if (signal is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(signal, (event) {
      final scroll = event as PointerScrollEvent;
      final isShiftPressed = HardwareKeyboard.instance.logicalKeysPressed.any(
        (key) =>
            key == LogicalKeyboardKey.shiftLeft ||
            key == LogicalKeyboardKey.shiftRight,
      );
      final horizontalDelta = scroll.scrollDelta.dx != 0
          ? scroll.scrollDelta.dx
          : scroll.scrollDelta.dy;
      if (isShiftPressed || scroll.scrollDelta.dx.abs() > 0.1) {
        _scrollBy(_horizontalController, horizontalDelta);
      } else if (_verticalController.hasClients &&
          _verticalController.position.maxScrollExtent > 0) {
        _scrollBy(_verticalController, scroll.scrollDelta.dy);
      } else {
        _scrollBy(_horizontalController, horizontalDelta);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final root = widget.report.activeManifest;
    if (root == null) {
      return const Center(child: Text('No manifest history found.'));
    }
    final manifestMap = <String, C2paManifest>{
      for (final item in widget.report.manifests) item.label: item,
    };
    final nodes = _buildC2paTreeNodes(
      root,
      manifestMap,
      widget.report.activeManifestLabel,
      p.basename(widget.clip.path),
    );
    final levelCount = nodes.fold<int>(
      0,
      (maximum, node) => math.max(maximum, node.depth + 1),
    );
    final widestLevel = List<int>.generate(levelCount, (depth) {
      return nodes.where((node) => node.depth == depth).length;
    }).fold<int>(1, math.max);
    final treeHeight =
        levelCount * _c2paTreeCardHeight +
        math.max(0, levelCount - 1) * _c2paTreeLevelGap +
        36;
    return Column(
      children: <Widget>[
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _c2paPanelBackground,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: _c2paCardBorder),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(17),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final treeWidth = math.max(
                      constraints.maxWidth,
                      widestLevel * 264.0,
                    );
                    return Listener(
                      key: const ValueKey<String>('c2pa-history-viewport'),
                      onPointerSignal: _handlePointerSignal,
                      child: Scrollbar(
                        controller: _verticalController,
                        thumbVisibility: true,
                        trackVisibility: true,
                        interactive: true,
                        notificationPredicate: (notification) =>
                            notification.metrics.axis == Axis.vertical,
                        child: Scrollbar(
                          controller: _horizontalController,
                          thumbVisibility: true,
                          trackVisibility: true,
                          interactive: true,
                          scrollbarOrientation: ScrollbarOrientation.bottom,
                          notificationPredicate: (notification) =>
                              notification.metrics.axis == Axis.horizontal,
                          child: SingleChildScrollView(
                            key: const ValueKey<String>(
                              'c2pa-history-horizontal',
                            ),
                            controller: _horizontalController,
                            scrollDirection: Axis.horizontal,
                            child: SizedBox(
                              width: treeWidth,
                              height: constraints.maxHeight,
                              child: SingleChildScrollView(
                                key: const ValueKey<String>(
                                  'c2pa-history-vertical',
                                ),
                                controller: _verticalController,
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  18,
                                  24,
                                  24,
                                ),
                                child: SizedBox(
                                  width: treeWidth - 40,
                                  height: treeHeight,
                                  child: _C2paTreeCanvas(nodes: nodes),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _C2paTreeNode {
  const _C2paTreeNode({
    required this.id,
    required this.depth,
    required this.parentId,
    required this.manifest,
    required this.ingredient,
    required this.title,
    required this.isActive,
  });

  final int id;
  final int depth;
  final int? parentId;
  final C2paManifest? manifest;
  final C2paIngredient? ingredient;
  final String title;
  final bool isActive;
}

class _C2paTreeCanvas extends StatelessWidget {
  const _C2paTreeCanvas({required this.nodes});

  final List<_C2paTreeNode> nodes;

  @override
  Widget build(BuildContext context) {
    final levels = <int, List<_C2paTreeNode>>{};
    for (final node in nodes) {
      levels.putIfAbsent(node.depth, () => <_C2paTreeNode>[]).add(node);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final positions = <int, Offset>{};
        final cards = <Widget>[];
        for (final entry in levels.entries) {
          final row = entry.value;
          final cellWidth = constraints.maxWidth / row.length;
          final top =
              18 + entry.key * (_c2paTreeCardHeight + _c2paTreeLevelGap);
          for (var index = 0; index < row.length; index++) {
            final node = row[index];
            final left = cellWidth * (index + 0.5) - _c2paTreeCardWidth / 2;
            positions[node.id] = Offset(left + _c2paTreeCardWidth / 2, top);
            cards.add(
              Positioned(
                left: left,
                top: top,
                child: _C2paTreeCard(
                  manifest: node.manifest,
                  ingredient: node.ingredient,
                  title: node.title,
                  isActive: node.isActive,
                ),
              ),
            );
          }
        }
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned.fill(
              child: CustomPaint(
                painter: _C2paTreeConnectorPainter(
                  nodes: nodes,
                  positions: positions,
                ),
              ),
            ),
            ...cards,
          ],
        );
      },
    );
  }
}

class _C2paTreeCard extends StatelessWidget {
  const _C2paTreeCard({
    required this.manifest,
    required this.ingredient,
    required this.title,
    required this.isActive,
  });

  final C2paManifest? manifest;
  final C2paIngredient? ingredient;
  final String title;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final actions = manifest?.actions ?? const <C2paAction>[];
    final thumbnailPath = ingredient?.thumbnailPath ?? manifest?.thumbnailPath;
    final issuer = manifest?.issuer ?? manifest?.commonName;
    final actionLabels = actions
        .map((action) => _friendlyC2paAction(action.action))
        .toSet()
        .take(4)
        .join(', ');
    final isAiGenerated = actions.any(
      (action) => _isAiDigitalSourceType(action.digitalSourceType),
    );
    return Center(
      child: Container(
        width: _c2paTreeCardWidth,
        height: _c2paTreeCardHeight,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 5),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isActive ? _c2paAccent : _c2paCardBorder,
            width: isActive ? 2 : 1,
          ),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x0D000000),
              blurRadius: 10,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              issuer == null ? 'Issuer unavailable' : 'Issuer · $issuer',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _c2paMutedText, fontSize: 11),
            ),
            const SizedBox(height: 4),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
            const SizedBox(height: 6),
            Stack(
              children: <Widget>[
                _C2paTreeThumbnail(
                  path: thumbnailPath,
                  format: manifest?.format ?? ingredient?.format,
                ),
                if (isAiGenerated)
                  const Positioned(
                    left: 6,
                    top: 6,
                    child: _C2paMiniTag(
                      label: 'AI Generated',
                      icon: Icons.smart_toy_outlined,
                      filled: true,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              actionLabels.isEmpty ? 'No declared actions' : actionLabels,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _c2paMutedText, fontSize: 11),
            ),
            if (manifest != null) ...<Widget>[
              const SizedBox(height: 6),
              const _C2paMiniTag(label: 'Content Credentials'),
            ] else if (ingredient?.relationship != null) ...<Widget>[
              const SizedBox(height: 6),
              _C2paMiniTag(label: ingredient!.relationship!),
            ],
          ],
        ),
      ),
    );
  }
}

class _C2paMiniTag extends StatelessWidget {
  const _C2paMiniTag({required this.label, this.icon, this.filled = false});

  final String label;
  final IconData? icon;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: filled ? 6 : 7,
        vertical: filled ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: filled ? const Color(0xFFFFE7DF) : Colors.transparent,
        border: Border.all(
          color: filled ? const Color(0xFFFFE7DF) : _c2paCardBorder,
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: filled ? 10 : 12, color: const Color(0xFFA0563D)),
            SizedBox(width: filled ? 3 : 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: const Color(0xFFA0563D),
                fontSize: filled ? 9 : 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _C2paTreeThumbnail extends StatelessWidget {
  const _C2paTreeThumbnail({required this.path, required this.format});

  final String? path;
  final String? format;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      key: const ValueKey<String>('c2pa-tree-thumbnail'),
      borderRadius: BorderRadius.circular(10),
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: ColoredBox(
          color: const Color(0xFF171A21),
          child: path == null
              ? _fallback()
              : Image.file(
                  File(path!),
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => _fallback(),
                ),
        ),
      ),
    );
  }

  Widget _fallback() {
    final isVideo = format?.startsWith('video/') ?? false;
    return Center(
      child: Icon(
        isVideo ? Icons.movie_outlined : Icons.image_outlined,
        size: 34,
        color: Colors.white38,
      ),
    );
  }
}

class _C2paTreeConnectorPainter extends CustomPainter {
  const _C2paTreeConnectorPainter({
    required this.nodes,
    required this.positions,
  });

  final List<_C2paTreeNode> nodes;
  final Map<int, Offset> positions;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFC9BFB2)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    for (final node in nodes) {
      if (node.parentId == null) continue;
      final parent = positions[node.parentId];
      final child = positions[node.id];
      if (parent == null || child == null) continue;
      final start = Offset(parent.dx, parent.dy + _c2paTreeCardHeight);
      final end = child;
      final middleY = (start.dy + end.dy) / 2;
      final path = Path()
        ..moveTo(start.dx, start.dy)
        ..lineTo(start.dx, middleY)
        ..lineTo(end.dx, middleY)
        ..lineTo(end.dx, end.dy);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_C2paTreeConnectorPainter oldDelegate) => true;
}

class _C2paTechnicalView extends StatelessWidget {
  const _C2paTechnicalView({required this.report});

  final C2paReport report;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Validation checks',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              '${report.passedCheckCount} passed · ${report.failedCheckCount} failed',
              style: const TextStyle(color: _c2paMutedText),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (report.validationEntries.isEmpty)
          const _C2paEmptyCard(
            message: 'No individual validation checks were reported.',
          )
        else
          ...report.validationEntries.map(
            (entry) => _C2paValidationTile(entry: entry),
          ),
        const SizedBox(height: 22),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Raw manifest JSON',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            TextButton.icon(
              key: const ValueKey<String>('copy-c2pa-json'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: report.rawJson));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('C2PA JSON copied')),
                );
              },
              icon: const Icon(Icons.copy_outlined, size: 17),
              label: const Text('Copy'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: _c2paCardBorder),
            borderRadius: BorderRadius.circular(14),
          ),
          child: SelectableText(
            report.rawJson,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11.5,
              color: Color(0xFF303642),
              height: 1.45,
            ),
          ),
        ),
      ],
    );
  }
}

class _C2paValidationTile extends StatelessWidget {
  const _C2paValidationTile({required this.entry});

  final C2paValidationEntry entry;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (entry.outcome) {
      C2paValidationOutcome.passed => (
        Icons.check_circle_outline,
        const Color(0xFF168A58),
      ),
      C2paValidationOutcome.failed => (
        Icons.error_outline,
        const Color(0xFFC43D35),
      ),
      C2paValidationOutcome.informational => (
        Icons.info_outline,
        const Color(0xFF526071),
      ),
    };
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: _c2paCardBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      margin: const EdgeInsets.only(bottom: 7),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(
          entry.code,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: entry.explanation == null ? null : Text(entry.explanation!),
      ),
    );
  }
}

class _C2paEmptyCard extends StatelessWidget {
  const _C2paEmptyCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _c2paCardBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(message, style: const TextStyle(color: _c2paMutedText)),
    );
  }
}

List<_C2paTreeNode> _buildC2paTreeNodes(
  C2paManifest root,
  Map<String, C2paManifest> manifests,
  String activeLabel,
  String fallbackTitle,
) {
  final nodes = <_C2paTreeNode>[];

  void addNode({
    required C2paManifest? manifest,
    required C2paIngredient? ingredient,
    required int? parentId,
    required int depth,
    required String title,
    required Set<String> visited,
  }) {
    final id = nodes.length;
    nodes.add(
      _C2paTreeNode(
        id: id,
        depth: depth,
        parentId: parentId,
        manifest: manifest,
        ingredient: ingredient,
        title: manifest?.title ?? ingredient?.title ?? title,
        isActive: manifest?.label == activeLabel,
      ),
    );
    if (manifest == null || visited.contains(manifest.label)) return;
    final nextVisited = <String>{...visited, manifest.label};
    for (final childIngredient in manifest.ingredients) {
      final linked = childIngredient.manifestLabel == null
          ? null
          : manifests[childIngredient.manifestLabel];
      final safeLinked = linked != null && !nextVisited.contains(linked.label)
          ? linked
          : null;
      addNode(
        manifest: safeLinked,
        ingredient: childIngredient,
        parentId: id,
        depth: depth + 1,
        title: childIngredient.title ?? 'Ingredient',
        visited: nextVisited,
      );
    }
  }

  addNode(
    manifest: root,
    ingredient: null,
    parentId: null,
    depth: 0,
    title: fallbackTitle,
    visited: const <String>{},
  );
  return nodes;
}

String _c2paStatusLabel(C2paStatus status) => switch (status) {
  C2paStatus.conformant => 'Trusted',
  C2paStatus.legacyTrusted => 'Legacy trusted',
  C2paStatus.untrusted => 'Valid · unverified signer',
  C2paStatus.invalid => 'Invalid',
  C2paStatus.absent => 'No credentials',
  C2paStatus.unknown => 'Unknown',
};

Color _c2paStatusColor(C2paStatus status) => switch (status) {
  C2paStatus.invalid => const Color(0xFFC62828),
  C2paStatus.untrusted => const Color(0xFFF9A825),
  C2paStatus.legacyTrusted => const Color(0xFF00897B),
  C2paStatus.conformant => const Color(0xFF2E7D32),
  C2paStatus.unknown || C2paStatus.absent => const Color(0xFF8C98A8),
};

String _friendlyC2paAction(String value) {
  final short = _shortC2paValue(value).replaceAll('_', ' ');
  if (short.isEmpty) return 'Unknown action';
  return '${short[0].toUpperCase()}${short.substring(1)}';
}

String _shortC2paValue(String value) {
  final hashIndex = value.lastIndexOf('#');
  if (hashIndex >= 0 && hashIndex < value.length - 1) {
    return value.substring(hashIndex + 1);
  }
  final slashIndex = value.lastIndexOf('/');
  if (slashIndex >= 0 && slashIndex < value.length - 1) {
    return value.substring(slashIndex + 1);
  }
  final dotIndex = value.lastIndexOf('.');
  return dotIndex >= 0 && dotIndex < value.length - 1
      ? value.substring(dotIndex + 1)
      : value;
}

bool _isAiDigitalSourceType(String? value) {
  if (value == null) return false;
  final normalized = value.toLowerCase();
  return normalized.contains('trainedalgorithmicmedia') ||
      normalized.contains('compositesynthetic') ||
      normalized.contains('algorithmicallyenhanced');
}

