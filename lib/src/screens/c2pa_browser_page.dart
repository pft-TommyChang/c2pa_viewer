import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../models.dart';
import '../services/c2pa_test_sign_service.dart';
import '../services/c2pa_write_options_store.dart';
import '../services/github_update_service.dart';
import '../services/media_inspection_service.dart' show MediaInspectionService;
import '../services/mobile_c2pa_service.dart';

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

// True on iOS/Android — use long-press; desktop uses double-tap.
bool get _isMobile => Platform.isIOS || Platform.isAndroid;
const Color _c2paPanelBackground = Color(0xFFF3EFE7);
const Color _c2paCardBorder = Color(0xFFD8D0C4);
const Color _c2paMutedText = Color(0xFF697180);
const Color _c2paAccent = Color(0xFFFF7A59);
const Color _c2paAccentDark = Color(0xFFD95C3E);
const double _c2paSectionGap = 7;
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
typedef C2paTestSignDestinationPicker =
    Future<String?> Function(VideoClipInfo clip, C2paWriteMode mode);

Future<void> _revealMediaFile(String path) async {
  if (Platform.isWindows) {
    await Process.run('explorer.exe', <String>['/select,', path]);
    return;
  }
  await Process.run('open', <String>['-R', path]);
}

class C2paBrowserPage extends StatefulWidget {
  const C2paBrowserPage({
    super.key,
    required this.mediaLoader,
    this.pendingPaths = const [],
    this.openGeneration = 0,
    this.testWriter,
    this.testSignDestinationPicker,
    this.writeOptionsStore,
    this.checkForUpdatesOnLaunch = true,
    this.updateService = const GitHubUpdateService(
      owner: 'pft-TommyChang',
      repository: 'c2pa_viewer',
    ),
  });

  final C2paMediaLoader mediaLoader;
  final List<String> pendingPaths;
  final int openGeneration;
  final C2paTestWriter? testWriter;
  final C2paTestSignDestinationPicker? testSignDestinationPicker;
  final C2paWriteOptionsStore? writeOptionsStore;
  final bool checkForUpdatesOnLaunch;
  final GitHubUpdateService updateService;

  @override
  State<C2paBrowserPage> createState() => _C2paBrowserPageState();
}

class _C2paBrowserPageState extends State<C2paBrowserPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late VideoClipInfo _clip;
  late VideoPlayerController? _controller;
  bool _isDragging = false;
  bool _isParsing = false;
  bool _isTestSigning = false;
  bool _hasMedia = false;
  int _parseGeneration = 0;
  final List<String> _history = [];
  int _historyIndex = -1;
  final FocusNode _focusNode = FocusNode();
  final GlobalKey<_C2paTechnicalViewState> _technicalViewKey =
      GlobalKey<_C2paTechnicalViewState>();
  C2paWriteOptionsStore? _writeOptionsStore;
  C2paWriteOptions? _lastWriteOptions;
  Future<void> _writeOptionsSaveQueue = Future<void>.value();

  // Tab controller so we can read active tab index during build.
  late TabController _tabController;
  // When true, History tree is in "fit" mode → allow swipe-to-change-tab.
  bool _historyZoomIsFit = true;

  // Update check
  GitHubRelease? _availableUpdate;
  String _versionLabel = '';
  bool _isCheckingForUpdates = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 3, vsync: this)
      // Rebuild on tab change so TabBarView physics update.
      ..addListener(() {
        if (mounted) setState(() {});
      });
    _clip = _emptyC2paClip();
    _controller = null;
    _writeOptionsStore = widget.writeOptionsStore;
    if (widget.pendingPaths.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_openPendingPaths(widget.pendingPaths));
      });
    }
    unawaited(_loadAppVersion());
    if (widget.checkForUpdatesOnLaunch) {
      unawaited(_checkForUpdatesInBackground());
    }
  }

  Future<void> _loadAppVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() => _versionLabel = 'v${info.version} (${info.buildNumber})');
    }
  }

  Future<void> _checkForUpdatesInBackground() async {
    if (_isCheckingForUpdates) return;
    _isCheckingForUpdates = true;
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final release = await widget.updateService.fetchLatestRelease();
      if (!mounted) return;
      final hasUpdate = GitHubUpdateService.isNewerVersion(
        currentVersion: packageInfo.version,
        releaseTag: release.tagName,
      );
      if (hasUpdate) {
        setState(() => _availableUpdate = release);
      }
    } catch (error) {
      debugPrint('Background update check failed: $error');
    } finally {
      _isCheckingForUpdates = false;
    }
  }

  Future<void> _openReleasePage() async {
    final pageUrl = Uri.https(
      'github.com',
      '/${widget.updateService.owner}/${widget.updateService.repository}/releases',
    );
    try {
      final didLaunch = await launchUrl(
        pageUrl,
        mode: LaunchMode.externalApplication,
      );
      if (!didLaunch && mounted) {
        debugPrint('Unable to open the GitHub Release page.');
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final technicalView = _technicalViewKey.currentState;
      if (_tabController.index == 2 &&
          technicalView != null &&
          technicalView.searchIsOpen) {
        technicalView.restoreKeyboardFocus();
      } else {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  void didUpdateWidget(C2paBrowserPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.openGeneration != oldWidget.openGeneration &&
        widget.pendingPaths.isNotEmpty) {
      // Defer the handoff until the rebuilt page has completed its frame.
      final paths = List<String>.of(widget.pendingPaths);
      final generation = widget.openGeneration;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || widget.openGeneration != generation) return;
        unawaited(_openPendingPaths(paths));
      });
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
    final mobile = Platform.isIOS;
    if (mobile) {
      // On iOS, always open Camera Roll via PHPickerViewController so the
      // original binary (including embedded C2PA) is returned intact.
      // ImagePicker re-encodes and strips C2PA, so we use the native channel.
      final originalPath = await MobileC2paService.pickOriginalMedia();
      if (originalPath != null) await _inspectPath(originalPath);
    } else {
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
  }

  // Pick media from the Files app (system document picker).
  Future<void> _pickMediaFromFiles() async {
    // iOS requires uniformTypeIdentifiers; extensions alone cause an exception.
    final file = await openFile(
      acceptedTypeGroups: <XTypeGroup>[
        if (Platform.isIOS)
          const XTypeGroup(
            label: 'Photos and videos',
            uniformTypeIdentifiers: <String>['public.image', 'public.movie'],
          )
        else
          const XTypeGroup(
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

  Future<void> _testSignCurrentMedia() async {
    if (!_hasMedia || _isParsing || _isTestSigning) return;
    final clip = _clip;
    final isMobile = Platform.isIOS || Platform.isAndroid;
    final initialOptions = isMobile
        ? const C2paWriteOptions(mode: C2paWriteMode.add, createNewFile: true)
        : await _loadWriteOptions();
    if (!mounted) return;
    final options = await showDialog<C2paWriteOptions>(
      context: context,
      builder: (_) => _C2paWriteTestDialog(
        initialOptions: initialOptions,
        onOptionsChanged: _rememberWriteOptions,
        mobileNative: isMobile,
      ),
    );
    await _writeOptionsSaveQueue;
    if (options == null || !mounted) return;

    var outputPath = clip.path;
    try {
      if (isMobile) {
        final extension = p.extension(clip.path).toLowerCase();
        outputPath = p.join(
          Directory.systemTemp.path,
          '${p.basenameWithoutExtension(clip.path)}_c2pa_${DateTime.now().millisecondsSinceEpoch}$extension',
        );
      } else if (options.createNewFile) {
        final destinationPicker =
            widget.testSignDestinationPicker ?? _pickTestSignDestination;
        final selectedPath = await destinationPicker(clip, options.mode);
        if (selectedPath == null || !mounted) return;
        if (p.equals(p.absolute(selectedPath), p.absolute(clip.path))) {
          _showErrorToast(
            'Choose a different output file, or turn off Create new file.',
          );
          return;
        }
        outputPath = selectedPath;
      }
    } catch (error) {
      _showErrorToast('$error');
      return;
    }
    setState(() => _isTestSigning = true);
    try {
      final writer = widget.testWriter ?? const C2paTestSignService().write;
      await writer(clip, outputPath, options.mode);
      if (!mounted) return;
      await _inspectPath(
        outputPath,
        addToHistory: !p.equals(p.absolute(outputPath), p.absolute(clip.path)),
      );
      if (isMobile && mounted) {
        try {
          await MobileC2paService.saveToPhotoLibrary(outputPath);
          _showErrorToast(
            options.mode == C2paWriteMode.remove
                ? 'Saved media without C2PA to Photos.'
                : 'Saved media with C2PA to Photos.',
          );
        } catch (saveError) {
          _showErrorToast(
            'Could not save to Photos directly, using share sheet instead: $saveError',
          );
          if (!mounted) return;
          final box = context.findRenderObject() as RenderBox?;
          await SharePlus.instance.share(
            ShareParams(
              files: <XFile>[XFile(outputPath)],
              title: 'Export signed Content Credentials',
              sharePositionOrigin: box == null
                  ? null
                  : box.localToGlobal(Offset.zero) & box.size,
            ),
          );
        }
      }
    } catch (error) {
      _showErrorToast('$error');
    } finally {
      if (mounted) setState(() => _isTestSigning = false);
    }
  }

  Future<C2paWriteOptions> _loadWriteOptions() async {
    final cached = _lastWriteOptions;
    if (cached != null) return cached;
    try {
      final options = await _resolvedWriteOptionsStore.load();
      _lastWriteOptions = options;
      return options;
    } catch (error) {
      debugPrint('Unable to load C2PA write preferences: $error');
      return const C2paWriteOptions(
        mode: C2paWriteMode.add,
        createNewFile: true,
      );
    }
  }

  void _rememberWriteOptions(C2paWriteOptions options) {
    _lastWriteOptions = options;
    _writeOptionsSaveQueue = _writeOptionsSaveQueue.then(
      (_) => _saveWriteOptions(options),
    );
  }

  Future<void> _saveWriteOptions(C2paWriteOptions options) async {
    try {
      await _resolvedWriteOptionsStore.save(options);
    } catch (error) {
      debugPrint('Unable to save C2PA write preferences: $error');
    }
  }

  C2paWriteOptionsStore get _resolvedWriteOptionsStore {
    return _writeOptionsStore ??= SharedPreferencesC2paWriteOptionsStore();
  }

  Future<String?> _pickTestSignDestination(
    VideoClipInfo clip,
    C2paWriteMode mode,
  ) async {
    final extension = p.extension(clip.path).toLowerCase();
    final suffix = switch (mode) {
      C2paWriteMode.add => 'c2pa_added',
      C2paWriteMode.replace => 'c2pa_replaced',
      C2paWriteMode.remove => 'c2pa_removed',
    };
    final location = await getSaveLocation(
      acceptedTypeGroups: <XTypeGroup>[
        XTypeGroup(
          label: '${extension.substring(1).toUpperCase()} media',
          extensions: <String>[extension.substring(1)],
        ),
      ],
      initialDirectory: p.dirname(clip.path),
      suggestedName:
          '${p.basenameWithoutExtension(clip.path)}_$suffix$extension',
      confirmButtonText: 'Export',
    );
    return location?.path;
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
    final isTextFieldFocused =
        FocusManager.instance.primaryFocus?.context?.widget is EditableText;
    if (!isTextFieldFocused &&
        (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.arrowRight)) {
      final delta = event.logicalKey == LogicalKeyboardKey.arrowLeft ? -1 : 1;
      final nextTab = _tabController.index + delta;
      if (nextTab >= 0 && nextTab < _tabController.length) {
        _tabController.animateTo(nextTab);
        return KeyEventResult.handled;
      }
      if (delta < 0 && _canGoPrev) {
        unawaited(_navigatePrev());
        return KeyEventResult.handled;
      }
      if (delta > 0 && _canGoNext) {
        unawaited(_navigateNext());
        return KeyEventResult.handled;
      }
    }
    final technicalView = _technicalViewKey.currentState;
    if (_tabController.index == 2 && technicalView != null) {
      final keyboard = HardwareKeyboard.instance;
      if (event.logicalKey == LogicalKeyboardKey.keyF &&
          (keyboard.isMetaPressed || keyboard.isControlPressed)) {
        technicalView.openSearch();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        technicalView.closeSearch();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.enter) {
        technicalView.moveMatch(keyboard.isShiftPressed ? -1 : 1);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.f3) {
        technicalView.moveMatch(keyboard.isShiftPressed ? -1 : 1);
        return KeyEventResult.handled;
      }
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
          bottom: false,
          child: DropTarget(
            onDragEntered: (_) => setState(() => _isDragging = true),
            onDragExited: (_) => setState(() => _isDragging = false),
            onDragDone: (details) => unawaited(_handleDrop(details.files)),
            child: Stack(
              children: <Widget>[
                Column(
                  children: <Widget>[
                    _C2paPageHeader(
                      clip: _hasMedia ? _clip : null,
                      onOpen: () => unawaited(_pickMedia()),
                      onOpenFromFiles: Platform.isIOS || Platform.isAndroid
                          ? () => unawaited(_pickMediaFromFiles())
                          : null,
                      onTestSign: () => unawaited(_testSignCurrentMedia()),
                      canTestSign:
                          _hasMedia &&
                          !_isParsing &&
                          !_isTestSigning &&
                          (!(Platform.isIOS || Platform.isAndroid) ||
                              const <String>{
                                '.jpg',
                                '.jpeg',
                                '.png',
                                '.webp',
                                '.tif',
                                '.tiff',
                                '.heic',
                                '.mp4',
                                '.mov',
                              }.contains(
                                p.extension(_clip.path).toLowerCase(),
                              )),
                      isTestSigning: _isTestSigning,
                      onPrev: () => unawaited(_navigatePrev()),
                      onNext: () => unawaited(_navigateNext()),
                      canGoPrev: _canGoPrev,
                      canGoNext: _canGoNext,
                      versionLabel: _versionLabel,
                      availableUpdate: _availableUpdate,
                      onUpdateTap: () => unawaited(_openReleasePage()),
                    ),
                    // Tab bar: always shown when media loaded;
                    // disabled (dimmed, non-interactive) when no C2PA report.
                    if (_hasMedia)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                        child: Material(
                          color: _c2paPanelBackground,
                          borderRadius: BorderRadius.circular(14),
                          clipBehavior: Clip.antiAlias,
                          child: SizedBox(
                            height: 44,
                            child: TabBar(
                              controller: _tabController,
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
                              overlayColor: WidgetStatePropertyAll<Color>(
                                Color(0x08697180),
                              ),
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
                                  mobileLabel: 'Checks',
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (_hasMedia) ...<Widget>[
                      const SizedBox(height: _c2paSectionGap),
                      _C2paFileLocationBar(path: _clip.path),
                    ],
                    Expanded(
                      // ClipRect prevents elastic-overscroll content from
                      // bleeding above the tab bar / page header on macOS.
                      child: ClipRect(
                        child: !_hasMedia && _isParsing
                            ? const _C2paParsingView()
                            : !_hasMedia
                            ? AnimatedOpacity(
                                duration: const Duration(milliseconds: 140),
                                opacity: _isDragging ? 0 : 1,
                                child: _C2paAwaitingMediaView(
                                  onTap: _pickMedia,
                                  onTapFiles: _pickMediaFromFiles,
                                ),
                              )
                            : TabBarView(
                                controller: _tabController,
                                // Mobile: lock swipe when on History tab and
                                // not fit-mode, so InteractiveViewer pan wins.
                                // In fit-mode the user likely intends to swipe
                                // tabs, not pan an already-fitted canvas.
                                physics:
                                    (Platform.isIOS || Platform.isAndroid) &&
                                        _tabController.index == 1 &&
                                        !_historyZoomIsFit
                                    ? const NeverScrollableScrollPhysics()
                                    : null,
                                children: <Widget>[
                                  _C2paOverview(
                                    clip: _clip,
                                    report: report,
                                    controller: _controller,
                                  ),
                                  _C2paHistoryTree(
                                    clip: _clip,
                                    report: report,
                                    onZoomModeChanged: (mode) => setState(
                                      () => _historyZoomIsFit =
                                          mode == _ZoomMode.fit,
                                    ),
                                  ),
                                  _C2paTechnicalView(
                                    key: _technicalViewKey,
                                    report: report,
                                  ),
                                ],
                              ),
                      ), // ClipRect
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _C2paTab extends StatelessWidget {
  const _C2paTab({required this.icon, required this.label, this.mobileLabel});

  final IconData icon;
  final String label;
  // Shorter label shown on mobile (no icon).
  final String? mobileLabel;

  @override
  Widget build(BuildContext context) {
    final isMobile = Platform.isIOS || Platform.isAndroid;
    if (isMobile) {
      return Tab(text: mobileLabel ?? label);
    }
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

class _C2paWriteTestDialog extends StatefulWidget {
  const _C2paWriteTestDialog({
    required this.initialOptions,
    required this.onOptionsChanged,
    this.mobileNative = false,
  });

  final C2paWriteOptions initialOptions;
  final ValueChanged<C2paWriteOptions> onOptionsChanged;
  final bool mobileNative;

  @override
  State<_C2paWriteTestDialog> createState() => _C2paWriteTestDialogState();
}

class _C2paWriteTestDialogState extends State<_C2paWriteTestDialog> {
  late C2paWriteMode _mode;
  late bool _createNewFile;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialOptions.mode;
    _createNewFile = widget.initialOptions.createNewFile;
  }

  void _updateOptions({C2paWriteMode? mode, bool? createNewFile}) {
    setState(() {
      _mode = mode ?? _mode;
      _createNewFile = createNewFile ?? _createNewFile;
    });
    widget.onOptionsChanged(
      C2paWriteOptions(mode: _mode, createNewFile: _createNewFile),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey<String>('c2pa-write-test-dialog'),
      title: const Text('C2PA write test'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            const Text('Select the C2PA operation to apply.'),
            if (widget.mobileNative) ...const <Widget>[
              SizedBox(height: 8),
              Text('The result is saved to the device media library.'),
            ],
            const SizedBox(height: 12),
            RadioGroup<C2paWriteMode>(
              groupValue: _mode,
              onChanged: (value) {
                if (value != null) _updateOptions(mode: value);
              },
              child: Column(
                children: <Widget>[
                  const RadioListTile<C2paWriteMode>(
                    key: ValueKey<String>('c2pa-write-add'),
                    value: C2paWriteMode.add,
                    title: Text('Add C2PA'),
                    subtitle: Text(
                      'Keep existing C2PA as parent, add a new claim',
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                  const RadioListTile<C2paWriteMode>(
                    key: ValueKey<String>('c2pa-write-replace'),
                    value: C2paWriteMode.replace,
                    title: Text('Replace C2PA'),
                    subtitle: Text(
                      'Discard existing C2PA, write a fresh claim',
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                  const RadioListTile<C2paWriteMode>(
                    key: ValueKey<String>('c2pa-write-remove'),
                    value: C2paWriteMode.remove,
                    title: Text('Remove C2PA'),
                    subtitle: Text('Strip all Content Credentials'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
            const Divider(),
            if (!widget.mobileNative)
              CheckboxListTile(
                key: const ValueKey<String>('c2pa-create-new-file'),
                value: _createNewFile,
                onChanged: (value) {
                  _updateOptions(createNewFile: value ?? false);
                },
                title: const Text('Create new file'),
                subtitle: Text(
                  _createNewFile
                      ? 'Save to a new file and keep the original'
                      : 'Overwrite the current file in place',
                ),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey<String>('run-c2pa-write-test'),
          onPressed: () => Navigator.of(
            context,
          ).pop(C2paWriteOptions(mode: _mode, createNewFile: _createNewFile)),
          child: const Text('Run'),
        ),
      ],
    );
  }
}

class _C2paPageHeader extends StatelessWidget {
  const _C2paPageHeader({
    required this.clip,
    required this.onOpen,
    this.onOpenFromFiles,
    required this.onTestSign,
    required this.canTestSign,
    required this.isTestSigning,
    required this.onPrev,
    required this.onNext,
    required this.canGoPrev,
    required this.canGoNext,
    this.versionLabel = '',
    this.availableUpdate,
    this.onUpdateTap,
  });

  final VideoClipInfo? clip;
  final VoidCallback onOpen;
  final VoidCallback? onOpenFromFiles;
  final VoidCallback onTestSign;
  final bool canTestSign;
  final bool isTestSigning;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final bool canGoPrev;
  final bool canGoNext;
  final String versionLabel;
  final GitHubRelease? availableUpdate;
  final VoidCallback? onUpdateTap;

  @override
  Widget build(BuildContext context) {
    final status = clip?.aiMetadata.c2paStatus;
    final compact = MediaQuery.sizeOf(context).width < 600;
    return ColoredBox(
      color: _c2paPageBackground,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          compact ? 12 : 20,
          12,
          compact ? 4 : 10,
          _c2paSectionGap,
        ),
        child: Row(
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/app_icon_nobg.png',
                width: compact ? 30 : 34,
                height: compact ? 30 : 34,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Content Credentials',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (!compact && versionLabel.isNotEmpty)
                    Tooltip(
                      message: availableUpdate != null
                          ? 'Version ${availableUpdate!.version} available — click to open'
                          : 'Open GitHub Releases',
                      child: InkWell(
                        key: const ValueKey<String>('open-release-page'),
                        onTap: onUpdateTap,
                        borderRadius: BorderRadius.circular(4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              versionLabel,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: _c2paMutedText,
                                    fontSize: 10,
                                    height: 1,
                                  ),
                            ),
                            if (availableUpdate != null) ...<Widget>[
                              const SizedBox(width: 3),
                              const Icon(
                                Icons.error_rounded,
                                key: ValueKey<String>(
                                  'update-available-indicator',
                                ),
                                size: 12,
                                color: Color(0xFFE0523D),
                              ),
                            ],
                          ],
                        ),
                      ),
                    )
                  else if (!compact && clip == null)
                    Text(
                      'Drop a media file anywhere on this page',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: _c2paMutedText),
                    ),
                ],
              ),
            ),
            if (!compact && status != null) _C2paStatusPill(status: status),
            const SizedBox(width: 6),
            IconButton(
              key: const ValueKey<String>('test-sign-media'),
              tooltip: 'Test sign current media',
              onPressed: canTestSign ? onTestSign : null,
              icon: isTestSigning
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.draw_outlined),
            ),
            if (!compact) ...<Widget>[
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
            ],
            // On mobile: tap = Camera Roll, long press = show menu
            if (onOpenFromFiles != null)
              GestureDetector(
                onTap: onOpen,
                onLongPress: () async {
                  HapticFeedback.mediumImpact();
                  final iconBox = context.findRenderObject() as RenderBox?;
                  if (iconBox == null) return;
                  final pos = iconBox.localToGlobal(Offset.zero);
                  final size = iconBox.size;
                  final screenW = MediaQuery.of(context).size.width;
                  final choice = await showMenu<String>(
                    context: context,
                    position: RelativeRect.fromLTRB(
                      // Anchor right edge of menu to right edge of button
                      screenW,
                      pos.dy + size.height,
                      screenW - (pos.dx + size.width),
                      pos.dy + size.height + 4,
                    ),
                    items: const <PopupMenuEntry<String>>[
                      PopupMenuItem<String>(
                        value: 'camera_roll',
                        child: Row(
                          children: <Widget>[
                            Icon(Icons.photo_library_outlined, size: 20),
                            SizedBox(width: 10),
                            Text('Camera Roll'),
                          ],
                        ),
                      ),
                      PopupMenuItem<String>(
                        value: 'files',
                        child: Row(
                          children: <Widget>[
                            Icon(Icons.folder_open_outlined, size: 20),
                            SizedBox(width: 10),
                            Text('Files'),
                          ],
                        ),
                      ),
                    ],
                  );
                  if (choice == 'camera_roll') onOpen();
                  if (choice == 'files') onOpenFromFiles!();
                },
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.folder_open_outlined),
                ),
              )
            else
              IconButton(
                key: const ValueKey<String>('open-media-file'),
                tooltip: 'Open media',
                onPressed: onOpen,
                icon: const Icon(Icons.folder_open_outlined),
              ),
          ],
        ),
      ),
    );
  }
}

class _C2paFileLocationBar extends StatefulWidget {
  const _C2paFileLocationBar({required this.path});

  final String path;

  @override
  State<_C2paFileLocationBar> createState() => _C2paFileLocationBarState();
}

class _C2paFileLocationBarState extends State<_C2paFileLocationBar> {
  // Holds the last successfully loaded video thumbnail bytes.
  // Not cleared on path change — old image stays visible until new one
  // arrives, giving a gapless crossfade between files.
  Uint8List? _thumbBytes;

  @override
  void initState() {
    super.initState();
    _fetchThumb(widget.path);
  }

  @override
  void didUpdateWidget(_C2paFileLocationBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      // For photos: clear stale video bytes immediately.
      // For videos: keep _thumbBytes so old frame stays visible while
      //             the new thumbnail loads (gapless transition).
      final ext = p.extension(widget.path).toLowerCase();
      if (!_supportedVideoExtensions.contains(ext)) {
        setState(() => _thumbBytes = null);
      }
      _fetchThumb(widget.path);
    }
  }

  Future<void> _fetchThumb(String filePath) async {
    final ext = p.extension(filePath).toLowerCase();
    if (!_supportedVideoExtensions.contains(ext)) return;
    final bytes = await MediaInspectionService.thumbnail(filePath);
    if (mounted && filePath == widget.path && bytes != null) {
      setState(() => _thumbBytes = bytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.path;
    int? fileSize;
    try {
      fileSize = File(path).lengthSync();
    } on FileSystemException {
      fileSize = null;
    }
    final revealLabel = Platform.isWindows
        ? 'Show in File Explorer'
        : 'Reveal in Finder';
    final canReveal = Platform.isWindows || Platform.isMacOS;
    return Container(
      key: const ValueKey<String>('c2pa-file-location'),
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _c2paCardBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SelectionArea(
        child: Row(
          children: <Widget>[
            // Fixed-size thumbnail — always 34×34 so layout never shifts.
            // Videos: show placeholder icon while bytes load, then crossfade to
            // the real frame; images: decode from file with error fallback.
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 34,
                height: 34,
                child: Builder(
                  builder: (context) {
                    final ext = p.extension(path).toLowerCase();
                    final isVideo = _supportedVideoExtensions.contains(ext);
                    if (_thumbBytes != null) {
                      return Image.memory(
                        _thumbBytes!,
                        width: 34,
                        height: 34,
                        fit: BoxFit.cover,
                      );
                    }
                    if (isVideo) {
                      // Thumbnail still loading — show stable placeholder
                      return const Icon(
                        Icons.movie_outlined,
                        size: 20,
                        color: _c2paAccentDark,
                      );
                    }
                    return Image.file(
                      File(path),
                      width: 34,
                      height: 34,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stack) => const Icon(
                        Icons.insert_drive_file_outlined,
                        size: 20,
                        color: _c2paAccentDark,
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    p.basename(path),
                    key: const ValueKey<String>('c2pa-file-name'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  _C2paOverflowTooltipText(
                    key: const ValueKey<String>('c2pa-full-path'),
                    text: path,
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: _c2paMutedText),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (fileSize != null) ...<Widget>[
              Container(
                key: const ValueKey<String>('c2pa-file-size'),
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: _c2paPanelBackground,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  _formatFileSize(fileSize),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: _c2paMutedText,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 4),
            ],
            IconButton(
              key: const ValueKey<String>('copy-media-path'),
              tooltip: 'Copy full path',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: path));
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    const SnackBar(
                      content: Text('Full path copied'),
                      duration: Duration(seconds: 1),
                    ),
                  );
              },
              icon: const Icon(Icons.copy_outlined, size: 19),
            ),
            if (canReveal)
              IconButton(
                key: const ValueKey<String>('reveal-media-file'),
                tooltip: revealLabel,
                onPressed: () => unawaited(_revealMediaFile(path)),
                icon: const Icon(Icons.folder_open_outlined, size: 20),
              ),
          ],
        ),
      ),
    );
  }
}

class _C2paOverflowTooltipText extends StatelessWidget {
  const _C2paOverflowTooltipText({super.key, required this.text, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final textWidget = Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        );
        if (!constraints.maxWidth.isFinite) return textWidget;

        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        return painter.didExceedMaxLines
            ? Tooltip(message: text, child: textWidget)
            : textWidget;
      },
    );
  }
}

String _formatFileSize(int bytes) {
  const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  final fractionDigits = unitIndex > 0 && value < 10 && value % 1 != 0 ? 1 : 0;
  return '${value.toStringAsFixed(fractionDigits)} ${units[unitIndex]}';
}

class _C2paDropPrompt extends StatelessWidget {
  const _C2paDropPrompt({this.prominent = false, this.onTap, this.onTapFiles});

  final bool prominent;
  final VoidCallback? onTap; // Camera Roll
  final VoidCallback? onTapFiles; // Files app

  @override
  Widget build(BuildContext context) {
    final isMobile = Platform.isIOS || Platform.isAndroid;
    final iconSize = prominent ? 44.0 : 36.0;

    // Mobile: bold title + two icon-text buttons
    Widget content;
    if (isMobile) {
      Widget sourceBtn(IconData icon, String label, VoidCallback? onPressed) {
        return Expanded(
          child: GestureDetector(
            onTap: onPressed,
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: _c2paAccentDark.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(icon, size: 28, color: _c2paAccentDark),
                  const SizedBox(height: 6),
                  Text(
                    label,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: _c2paAccentDark,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }

      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: double.infinity,
            child: Text(
              'Select a photo or video',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: <Widget>[
              sourceBtn(Icons.photo_library_outlined, 'Camera Roll', onTap),
              const SizedBox(width: 12),
              sourceBtn(Icons.folder_open_outlined, 'Files', onTapFiles),
            ],
          ),
        ],
      );
    } else {
      // Desktop: single download icon + drop hint text
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.file_download_outlined,
            size: iconSize,
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
      );
    }

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
        child: content,
      ),
    );
  }
}

// Empty state shown inside History / Check tabs when there is no C2PA report.
class _C2paTabEmptyState extends StatelessWidget {
  const _C2paTabEmptyState({
    required this.icon,
    required this.message,
    required this.subtitle,
  });

  final IconData icon;
  final String message;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 40, color: _c2paMutedText),
          const SizedBox(height: 12),
          Text(
            message,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(subtitle, style: const TextStyle(color: _c2paMutedText)),
        ],
      ),
    );
  }
}

class _C2paAwaitingMediaView extends StatelessWidget {
  const _C2paAwaitingMediaView({this.onTap, this.onTapFiles});

  final VoidCallback? onTap;
  final VoidCallback? onTapFiles;

  @override
  Widget build(BuildContext context) {
    // Position the prompt above center (~1/3 from top) on mobile.
    return Align(
      alignment: const Alignment(0, -0.2),
      child: _C2paDropPrompt(onTap: onTap, onTapFiles: onTapFiles),
    );
  }
}

class _C2paParsingView extends StatelessWidget {
  const _C2paParsingView();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      key: ValueKey<String>('c2pa-parsing-view'),
      color: _c2paPageBackground,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            SizedBox(height: 16),
            Text('Inspecting Content Credentials…'),
          ],
        ),
      ),
    );
  }
}

class _C2paNoCredentialsView extends StatelessWidget {
  const _C2paNoCredentialsView({required this.clip});

  final VideoClipInfo clip;

  @override
  Widget build(BuildContext context) {
    final isMobile = Platform.isIOS || Platform.isAndroid;
    // Shared info card widget used in both mobile and desktop layouts.
    final infoCard = Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _c2paCardBorder),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: isMobile ? MainAxisSize.min : MainAxisSize.max,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.gpp_maybe_outlined,
                size: 19,
                color: _c2paMutedText,
              ),
              const SizedBox(width: 8),
              // Expanded prevents text overflow in both layouts.
              Expanded(
                child: Text(
                  'No Content Credentials',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '${p.basename(clip.path)} does not contain C2PA data.',
            style: const TextStyle(color: _c2paMutedText, fontSize: 13),
          ),
        ],
      ),
    );
    return ListView(
      padding: EdgeInsets.fromLTRB(
        18,
        _c2paSectionGap,
        18,
        18 + MediaQuery.paddingOf(context).bottom,
      ),
      children: <Widget>[
        // Mobile: 4:3 full-width thumbnail then info card below (same pattern
        // as _C2paOverview). Desktop: side-by-side row at fixed height.
        if (isMobile) ...<Widget>[
          AspectRatio(
            aspectRatio: 4 / 3,
            child: _C2paPreviewCard(
              key: const ValueKey<String>('c2pa-no-cred-preview'),
              clip: clip,
            ),
          ),
          const SizedBox(height: 12),
          infoCard,
        ] else
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
                Expanded(child: infoCard),
              ],
            ),
          ),
        // Other Metadata section (exif/video metadata, no C2PA needed)
        if (clip.exifGroups.isNotEmpty) ...<Widget>[
          const SizedBox(height: 18),
          Text(
            'Other Metadata',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          _ExifGroupsCard(groups: clip.exifGroups, shrinkWrap: isMobile),
          const SizedBox(height: 6),
        ],
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
  final C2paReport? report;
  final VideoPlayerController? controller;

  @override
  Widget build(BuildContext context) {
    final report = this.report; // promote to non-nullable via flow analysis
    if (report == null) {
      return clip.aiMetadata.c2paStatus == C2paStatus.absent
          ? _C2paNoCredentialsView(clip: clip)
          : _C2paUnavailableView(clip: clip);
    }
    final manifest = report.activeManifest;
    final isMobile = Platform.isIOS || Platform.isAndroid;
    // Reusable card widgets (keys must be stable across layouts).
    // shrinkWrap required on mobile: cards live inside ListView (unbounded height).
    final signerCard = _C2paInfoCard(
      key: const ValueKey<String>('c2pa-overview-signer'),
      title: 'Signer',
      icon: Icons.draw_outlined,
      rows: <(String, String?)>[
        ('Signer', manifest?.commonName),
        ('Issuer', manifest?.issuer),
        ('Algorithm', manifest?.algorithm),
        ('Signed', manifest?.signedAt),
        ('Software', manifest?.software),
      ],
      shrinkWrap: isMobile,
    );
    final manifestCard = _C2paInfoCard(
      key: const ValueKey<String>('c2pa-overview-manifest'),
      title: 'Manifest',
      icon: Icons.description_outlined,
      rows: <(String, String?)>[
        (
          'Title',
          manifest?.title?.trim().isNotEmpty == true
              ? manifest!.title
              : 'Untitled asset',
        ),
        (
          'Format',
          manifest?.format ?? shortMediaTypeLabel(clip.path, clip.mediaKind),
        ),
        ('Claim Version', manifest?.claimVersion),
        ('Content type', manifest?.contentType),
        (
          'History',
          '${report.manifests.length} manifest${report.manifests.length == 1 ? '' : 's'}',
        ),
        (
          'Validation',
          '${report.passedCheckCount} passed · ${report.failedCheckCount} failed',
        ),
      ],
      shrinkWrap: isMobile,
    );
    return ListView(
      padding: EdgeInsets.fromLTRB(
        18,
        _c2paSectionGap,
        18,
        18 + MediaQuery.paddingOf(context).bottom,
      ),
      physics: !isMobile ? const ClampingScrollPhysics() : null,
      children: <Widget>[
        if (isMobile) ...<Widget>[
          AspectRatio(
            aspectRatio: 4 / 3,
            child: _C2paPreviewCard(
              key: const ValueKey<String>('c2pa-overview-preview'),
              clip: clip,
              controller: controller,
            ),
          ),
          const SizedBox(height: 12),
          signerCard,
          const SizedBox(height: 12),
          manifestCard,
        ] else
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
                Expanded(child: signerCard),
                const SizedBox(width: 12),
                Expanded(child: manifestCard),
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
        // Other Metadata section
        Builder(
          builder: (context) {
            final c2paGroup = _buildJumbfGroup(report);
            final allGroups = <String, Map<String, String>>{
              ...clip.exifGroups,
              if (c2paGroup.isNotEmpty) 'JUMBF': c2paGroup,
            };
            if (allGroups.isEmpty) return const SizedBox.shrink();
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const SizedBox(height: 18),
                Text(
                  'Other Metadata',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                _ExifGroupsCard(groups: allGroups, shrinkWrap: isMobile),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _C2paPreviewCard extends StatefulWidget {
  const _C2paPreviewCard({super.key, required this.clip, this.controller});

  final VideoClipInfo clip;
  final VideoPlayerController? controller;

  @override
  State<_C2paPreviewCard> createState() => _C2paPreviewCardState();
}

class _C2paPreviewCardState extends State<_C2paPreviewCard> {
  // Last successfully decoded thumbnail — held across file switches so
  // the old frame shows while the next thumbnail is loading (gapless).
  Uint8List? _thumb;

  @override
  void initState() {
    super.initState();
    if (!widget.clip.isPhoto) _fetchThumb(widget.clip.path);
  }

  @override
  void didUpdateWidget(_C2paPreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clip.path != widget.clip.path) {
      if (widget.clip.isPhoto) {
        setState(() => _thumb = null); // photos use Image.file
      } else {
        _fetchThumb(widget.clip.path); // keep _thumb until new bytes arrive
      }
    }
  }

  Future<void> _fetchThumb(String filePath) async {
    final bytes = await MediaInspectionService.thumbnail(filePath);
    if (mounted && filePath == widget.clip.path && bytes != null) {
      setState(() => _thumb = bytes);
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
              errorBuilder: (_, e, s) => const Icon(
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
          // Gapless: _thumb holds previous video frame until next one arrives.
          : _thumb != null
          ? Image.memory(_thumb!, fit: BoxFit.contain)
          : const Center(
              child: Icon(
                Icons.movie_outlined,
                size: 56,
                color: Colors.white54,
              ),
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// JUMBF group builder – mirrors metadataview.com JUMBF output from rawJson
// ---------------------------------------------------------------------------

String _binaryFieldLabel(dynamic value) {
  if (value is! String || value.isEmpty) return '$value';
  final raw = value.replaceAll(RegExp(r'[^A-Za-z0-9+/]'), '');
  final bytes = (raw.length * 3) ~/ 4;
  if (bytes == 0) return '<binary>';
  if (bytes < 1024) return '<binary, $bytes B> Show more';
  return '<binary, ${(bytes / 1024).toStringAsFixed(1)} KB> Show more';
}

// Joins a list of nullable values as "v1, v2, null, v3"
String _joinExclusionField(List<dynamic> exclusions, String field) {
  return exclusions
      .map((e) {
        final m = e as Map<String, dynamic>?;
        if (m == null) return 'null';
        final v = m[field];
        if (v == null) return 'null';
        if (v is List) return v.join(', ');
        return '$v';
      })
      .join(', ');
}

Map<String, String> _buildJumbfGroup(C2paReport report) {
  final result = <String, String>{};
  try {
    final root = jsonDecode(report.rawJson) as Map<String, dynamic>;
    final manifests = root['manifests'] as Map<String, dynamic>?;
    final activeLabel =
        (root['active_manifest'] as String?) ?? report.activeManifestLabel;
    final manifest = manifests?[activeLabel] as Map<String, dynamic>?;
    if (manifest == null) return result;

    void add(String key, dynamic v) {
      if (v != null && '$v'.isNotEmpty && v != 'null') result[key] = '$v';
    }

    // Signature info – Alg
    final sig = manifest['signature_info'] as Map<String, dynamic>?;
    add('Alg', sig?['alg']);

    // C2PA JUMBF fixed metadata
    result['JUMDType'] = '(c2pa)-0011-0010-800000aa00389b71';
    result['JUMDLabel'] = 'c2pa';

    // Signature reference: self#jumbf=/c2pa/{label}/c2pa.signature
    result['Signature'] = 'self#jumbf=/c2pa/$activeLabel/c2pa.signature';

    // InstanceID
    add('InstanceID', manifest['instance_id']);

    // claim_generator_info array
    final cgInfoList = manifest['claim_generator_info'] as List<dynamic>?;
    if (cgInfoList != null) {
      for (int ci = 0; ci < cgInfoList.length; ci++) {
        final cgi = cgInfoList[ci] as Map<String, dynamic>?;
        if (cgi == null) continue;
        final pfx = cgInfoList.length > 1
            ? 'Claim_Generator_Info${ci + 1}'
            : 'Claim_Generator_Info';
        add('${pfx}Name', cgi['name']);
        add('${pfx}Version', cgi['version']);
        // flatten org map: org → Org, org.contentauth → OrgContentauth, etc.
        final org = cgi['org'] as Map<String, dynamic>?;
        if (org != null) {
          void flattenOrg(Map<String, dynamic> m, String prefix) {
            for (final e in m.entries) {
              final sub =
                  '$prefix${e.key[0].toUpperCase()}${e.key.substring(1)}';
              if (e.value is Map<String, dynamic>) {
                flattenOrg(e.value as Map<String, dynamic>, sub);
              } else {
                add('$pfx$sub', e.value);
              }
            }
          }

          flattenOrg(org, 'Org');
        }
      }
    }

    // created_assertions / gathered_assertions (claim-level assertion references)
    void addAssertionRefs(String prefix, dynamic list) {
      final refs = list as List<dynamic>?;
      if (refs == null || refs.isEmpty) return;
      for (int ri = 0; ri < refs.length; ri++) {
        final ref = refs[ri] as Map<String, dynamic>?;
        if (ref == null) continue;
        final p = refs.length > 1 ? '$prefix${ri + 1}' : prefix;
        add('${p}Url', ref['url']);
        if (ref['hash'] != null) {
          result['${p}Hash'] = _binaryFieldLabel(ref['hash']);
        }
      }
    }

    addAssertionRefs('Created_Assertions', manifest['created_assertions']);
    addAssertionRefs('Gathered_Assertions', manifest['gathered_assertions']);

    // Assertions
    final assertions = manifest['assertions'] as List<dynamic>? ?? [];
    Map<String, dynamic>? hashData;
    Map<String, dynamic>? hashBmff;
    Map<String, dynamic>? actionsData;

    for (final raw in assertions) {
      final a = raw as Map<String, dynamic>?;
      if (a == null) continue;
      final label = a['label'] as String? ?? '';
      final data = a['data'] as Map<String, dynamic>?;
      if (data == null) continue;
      if (label == 'c2pa.hash.data') hashData = data;
      if (label.startsWith('c2pa.hash.bmff')) hashBmff = data;
      if (label.startsWith('c2pa.actions')) actionsData = a;
    }

    // c2pa.hash.data fields
    if (hashData != null) {
      if (hashData['hash'] != null) {
        result['Hash'] = _binaryFieldLabel(hashData['hash']);
      }
      add('Name', hashData['name']);
      if (hashData['pad'] != null) {
        result['Pad'] = _binaryFieldLabel(hashData['pad']);
      }
      final excls = hashData['exclusions'] as List<dynamic>?;
      if (excls != null && excls.isNotEmpty) {
        final ex = excls.first as Map<String, dynamic>?;
        add('ExclusionsStart', ex?['start']);
        add('ExclusionsLength', ex?['length']);
      }
      if (hashData['hash_salt'] != null) {
        result['C2PAHashDataSalt'] = _binaryFieldLabel(hashData['hash_salt']);
      }
    }

    // c2pa.hash.bmff.v3 exclusions – each field joined across all exclusion objects
    if (hashBmff != null) {
      final excls = hashBmff['exclusions'] as List<dynamic>? ?? [];
      if (excls.isNotEmpty) {
        for (final field in const <String>[
          'data',
          'exact',
          'flags',
          'xpath',
          'length',
          'subset',
          'version',
        ]) {
          final joined = _joinExclusionField(excls, field);
          // Capitalise first letter to match exiftool naming
          final key =
              'Exclusions${field[0].toUpperCase()}${field.substring(1)}';
          result[key] = joined;
        }
        // ExclusionsDataValue / ExclusionsDataOffset from exclusions with data
        for (final ex in excls) {
          final m = ex as Map<String, dynamic>?;
          if (m == null) continue;
          final d = m['data'] as Map<String, dynamic>?;
          if (d != null) {
            if (d['value'] != null) {
              result['ExclusionsDataValue'] = _binaryFieldLabel(d['value']);
            }
            add('ExclusionsDataOffset', d['offset']);
            break;
          }
        }
      }
      if (hashBmff['salt'] != null) {
        result['C2PAHashBmffV3Salt'] = _binaryFieldLabel(hashBmff['salt']);
      }
    }

    // c2pa.actions
    if (actionsData != null) {
      final data = actionsData['data'] as Map<String, dynamic>?;
      final actions = data?['actions'] as List<dynamic>? ?? [];
      for (int i = 0; i < actions.length; i++) {
        final act = actions[i] as Map<String, dynamic>?;
        if (act == null) continue;
        final prefix = actions.length > 1 ? 'Actions${i + 1}' : 'Actions';
        add('${prefix}When', act['when']);
        add('${prefix}Action', act['action']);
        add('${prefix}DigitalSourceType', act['digitalSourceType']);
        // softwareAgent may be a plain string or an object {name, version}
        final sa = act['softwareAgent'];
        if (sa is Map<String, dynamic>) {
          add('${prefix}SoftwareAgentName', sa['name']);
          add('${prefix}SoftwareAgentVersion', sa['version']);
        } else if (sa != null) {
          add('${prefix}SoftwareAgent', sa);
        }
        final params = act['parameters'] as Map<String, dynamic>?;
        if (params != null) {
          add('${prefix}ParametersName', params['name']);
          add('${prefix}ParametersTime', params['time'] ?? params['dateTime']);
          add('${prefix}ParametersLog_Id', params['log_id']);
          add('${prefix}ParametersModel_Name', params['model_name']);
          // any remaining scalar params not already handled
          const handledParams = <String>{
            'name',
            'time',
            'dateTime',
            'log_id',
            'model_name',
          };
          for (final pe in params.entries) {
            if (handledParams.contains(pe.key)) continue;
            if (pe.value is! Map && pe.value is! List) {
              add(
                '${prefix}Parameters'
                '${pe.key[0].toUpperCase()}${pe.key.substring(1)}',
                pe.value,
              );
            }
          }
        }
      }
      if (data?['salt'] != null) {
        result['C2PAActionsV2Salt'] = _binaryFieldLabel(data!['salt']);
      }
    }
  } catch (_) {}
  return result;
}

// Show a dialog with the full key/value and individual copy buttons.
Future<void> _showMetaEntryDialog(
  BuildContext context, {
  required String rawKey,
  required String value,
}) async {
  final displayKey = _friendlyMetaKey(rawKey);

  await showDialog<void>(
    context: context,
    builder: (ctx) {
      // Track which field was just copied so we can flash the icon.
      String? copiedField;

      // Bordered, scrollable, monospace box — looks like an EditText.
      Widget field(
        String label,
        String text,
        StateSetter setState, {
        bool scrollable = false,
      }) {
        const mono = TextStyle(
          fontSize: 12.5,
          fontFamily: 'Courier',
          fontFamilyFallback: <String>['Menlo', 'monospace'],
        );
        final inner = SelectableText(text, style: mono);
        final isCopied = copiedField == label;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 11,
                    color: _c2paMutedText,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: text));
                    setState(() => copiedField = label);
                    await Future<void>.delayed(
                      const Duration(milliseconds: 3000),
                    );
                    setState(() {
                      if (copiedField == label) copiedField = null;
                    });
                  },
                  // Fixed width prevents layout jump when switching states.
                  child: SizedBox(
                    width: 72,
                    height: 20,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: isCopied
                          ? const Row(
                              key: ValueKey<String>('check'),
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: <Widget>[
                                Icon(
                                  Icons.check,
                                  size: 14,
                                  color: Colors.green,
                                ),
                                SizedBox(width: 4),
                                Text(
                                  'Copied',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.green,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            )
                          : const Align(
                              key: ValueKey<String>('copy'),
                              alignment: Alignment.centerRight,
                              child: Icon(
                                Icons.copy_outlined,
                                size: 16,
                                color: _c2paAccentDark,
                              ),
                            ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                border: Border.all(color: _c2paCardBorder),
                borderRadius: BorderRadius.circular(8),
                // Transparent — inherits dialog surface colour.
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: scrollable
                  ? ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: SingleChildScrollView(child: inner),
                    )
                  : inner,
            ),
          ],
        );
      }

      return StatefulBuilder(
        builder: (ctx2, setState) => AlertDialog(
          title: const Text(
            'Metadata',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          // Shrinks to content width; max ~520 on wide screens.
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 40,
            vertical: 24,
          ),
          content: IntrinsicWidth(
            stepWidth: 64,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 240, maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  field('KEY', displayKey, setState),
                  const SizedBox(height: 16),
                  field('VALUE', value, setState, scrollable: true),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx2).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    },
  );
}

// Map raw metadata tag keys to human-friendly display names.
String _friendlyMetaKey(String key) {
  const Map<String, String> knownKeys = <String, String>{
    '%A9too': '© Tool',
    '%A9nam': '© Title',
    '%A9art': '© Artist',
    '%A9alb': '© Album',
    '%A9day': '© Year',
    '%A9cmt': '© Comment',
    '%A9gen': '© Genre',
    '%A9lyr': '© Lyrics',
    '%A9cpy': '© Copyright',
    '%A9enc': '© Encoded By',
    '%A9wrk': '© Work',
    '%A9grp': '© Grouping',
  };
  if (knownKeys.containsKey(key)) return knownKeys[key]!;
  // Handle %00%00%00%NN — QuickTime numeric-indexed metadata atoms
  final qtNumeric = RegExp(r'^(?:%00){3}%([0-9A-Fa-f]{2})$');
  final m = qtNumeric.firstMatch(key);
  if (m != null) {
    final idx = int.parse(m.group(1)!, radix: 16);
    return 'QT Key #$idx';
  }
  return key;
}

class _ExifGroupsCard extends StatefulWidget {
  const _ExifGroupsCard({required this.groups, this.shrinkWrap = false});

  final Map<String, Map<String, String>> groups;
  final bool shrinkWrap;

  @override
  State<_ExifGroupsCard> createState() => _ExifGroupsCardState();
}

class _ExifGroupsCardState extends State<_ExifGroupsCard> {
  // Track which groups are expanded; all start collapsed except FILE.
  late final Set<String> _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = <String>{'FILE'};
  }

  @override
  Widget build(BuildContext context) {
    final groups = widget.groups;
    // Preferred display order
    final ordered = const <String>[
      'FILE',
      'COMPOSITE',
      'EXIF',
      'GPS',
      'IPTC',
      'TIFF',
      'JFIF',
      'PNG',
      'QuickTime',
      'MakerApple',
      'JUMBF',
    ];
    final keys = <String>[
      ...ordered.where(groups.containsKey),
      ...groups.keys.where((k) => !ordered.contains(k)),
    ];

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _c2paCardBorder),
        borderRadius: BorderRadius.circular(18),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < keys.length; i++) ...<Widget>[
            if (i > 0)
              const Divider(height: 1, thickness: 1, color: _c2paCardBorder),
            _ExifGroupTile(
              name: keys[i],
              entries: keys[i] == 'MakerApple'
                  ? _remapMakerAppleKeys(groups[keys[i]]!)
                  : groups[keys[i]]!,
              expanded: _expanded.contains(keys[i]),
              onToggle: () => setState(() {
                if (_expanded.contains(keys[i])) {
                  _expanded.remove(keys[i]);
                } else {
                  _expanded.add(keys[i]);
                }
              }),
            ),
          ],
        ],
      ),
    );
  }

  /// Maps Apple MakerNote numeric tag IDs to human-readable names.
  /// Unknown tags fall back to "Tag_N".
  static Map<String, String> _remapMakerAppleKeys(Map<String, String> raw) {
    const known = <String, String>{
      '1': 'MakerNoteVersion',
      '2': 'AEStable',
      '3': 'AETarget',
      '4': 'AEAverage',
      '5': 'AFStable',
      '6': 'AccelerationVector',
      '8': 'HDRGain',
      '14': 'FocusDistanceRange',
      '17': 'BurstUUID',
      '19': 'FocusDistanceRange2',
      '23': 'OISMode',
      '25': 'GreenGhostMitigation',
      '29': 'MediaGroupUUID',
      '31': 'ImageUniqueID',
      '33': 'SigmaValue',
      '35': 'FocusDistanceRange3',
      '36': 'OISMode2',
      '38': 'ContentIdentifier',
      '39': 'ImageScale',
      '41': 'DeviceType',
      '43': 'CameraCalibrationData',
      '44': 'ImageCaptureType',
      '45': 'ImageProcessingFlags',
      '46': 'SequenceNumber',
      '47': 'MediaType',
      '48': 'FrameIndex',
      '49': 'ImageUniqueID2',
      '57': 'SlowQuarterFrame',
    };
    return <String, String>{
      for (final e in raw.entries) (known[e.key] ?? 'Tag_${e.key}'): e.value,
    };
  }
}

class _ExifGroupTile extends StatelessWidget {
  const _ExifGroupTile({
    required this.name,
    required this.entries,
    required this.expanded,
    required this.onToggle,
  });

  final String name;
  final Map<String, String> entries;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // Group header – tappable to expand/collapse
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            child: Row(
              children: <Widget>[
                Text(
                  name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    letterSpacing: 0.8,
                    color: _c2paAccentDark,
                  ),
                ),
                const Spacer(),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: _c2paMutedText,
                ),
              ],
            ),
          ),
        ),
        // Rows – shown when expanded
        if (expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: _C2paCopySelectionArea(
              rawAllText: entries.entries
                  .map(
                    (entry) => '${_friendlyMetaKey(entry.key)}${entry.value}',
                  )
                  .join(),
              copyAllText: entries.entries
                  .map(
                    (entry) => '${_friendlyMetaKey(entry.key)} ${entry.value}',
                  )
                  .join('\n'),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final entry in entries.entries) ...<Widget>[
                    const SizedBox(height: 6),
                    // Long-press opens the detail dialog. Double-click remains
                    // available for selecting the row's text on desktop.
                    GestureDetector(
                      onLongPress: () {
                        if (_isMobile) {
                          HapticFeedback.mediumImpact();
                        }
                        unawaited(
                          _showMetaEntryDialog(
                            context,
                            rawKey: entry.key,
                            value: entry.value,
                          ),
                        );
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: <Widget>[
                          SizedBox(
                            width: 130,
                            child: Text(
                              _friendlyMetaKey(entry.key),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _c2paMutedText,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              entry.value,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Keeps a data table's layout unchanged while formatting a full selection for
/// the clipboard. Flutter otherwise concatenates text from adjacent cells.
class _C2paCopySelectionArea extends StatefulWidget {
  const _C2paCopySelectionArea({
    required this.rawAllText,
    required this.copyAllText,
    required this.child,
  });

  final String rawAllText;
  final String copyAllText;
  final Widget child;

  @override
  State<_C2paCopySelectionArea> createState() => _C2paCopySelectionAreaState();
}

class _C2paCopySelectionAreaState extends State<_C2paCopySelectionArea> {
  String _selectedText = '';

  Future<void> _copySelection() {
    final text = _selectedText == widget.rawAllText
        ? widget.copyAllText
        : _selectedText;
    return Clipboard.setData(ClipboardData(text: text));
  }

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
          onInvoke: (_) {
            unawaited(_copySelection());
            return null;
          },
        ),
      },
      child: SelectionArea(
        onSelectionChanged: (content) =>
            _selectedText = content?.plainText ?? '',
        contextMenuBuilder: (context, selectableRegionState) {
          final buttons = selectableRegionState.contextMenuButtonItems
              .map(
                (item) => item.type == ContextMenuButtonType.copy
                    ? item.copyWith(
                        onPressed: () {
                          unawaited(_copySelection());
                          selectableRegionState.hideToolbar();
                        },
                      )
                    : item,
              )
              .toList(growable: false);
          return AdaptiveTextSelectionToolbar.buttonItems(
            anchors: selectableRegionState.contextMenuAnchors,
            buttonItems: buttons,
          );
        },
        child: widget.child,
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
    // shrinkWrap: true when the card is inside an unbounded-height parent
    // (e.g. ListView on mobile). Disables Expanded so the column sizes to
    // its content instead of requiring a finite parent height.
    this.shrinkWrap = false,
  });

  final String title;
  final IconData icon;
  final List<(String, String?)> rows;
  final bool shrinkWrap;

  List<Widget> _buildRows(BuildContext context) {
    final visibleRows = rows.where((row) => row.$2 != null).toList();
    return <Widget>[
      for (int i = 0; i < visibleRows.length; i++) ...<Widget>[
        if (i > 0) const SizedBox(height: 8),
        // Long-press opens the metadata dialog, keeping double-click free for
        // desktop text selection.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: () {
            if (_isMobile) HapticFeedback.mediumImpact();
            unawaited(
              _showMetaEntryDialog(
                context,
                rawKey: visibleRows[i].$1,
                value: visibleRows[i].$2!,
              ),
            );
          },
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 94,
                child: Text(
                  visibleRows[i].$1,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _c2paMutedText, fontSize: 12),
                ),
              ),
              Expanded(
                child: Text(
                  visibleRows[i].$2!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final visibleRows = rows.where((row) => row.$2 != null).toList();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _c2paCardBorder),
        borderRadius: BorderRadius.circular(18),
      ),
      child: _C2paCopySelectionArea(
        rawAllText:
            '$title${visibleRows.map((row) => '${row.$1}${row.$2}').join()}',
        copyAllText:
            '$title\n${visibleRows.map((row) => '${row.$1} ${row.$2}').join('\n')}',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: shrinkWrap ? MainAxisSize.min : MainAxisSize.max,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(icon, size: 19, color: _c2paAccentDark),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (shrinkWrap)
              // Unbounded context (mobile ListView): no Expanded, fixed spacing.
              LayoutBuilder(
                builder: (context, constraints) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _buildRows(context),
                  );
                },
              )
            else
              Expanded(
                child: Builder(
                  builder: (context) => SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _buildRows(context),
                    ),
                  ),
                ),
              ),
          ],
        ),
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
            child: _C2paCopySelectionArea(
              rawAllText:
                  '${_friendlyC2paAction(action.action)}${<String>[if (action.softwareAgent != null) action.softwareAgent!, if (action.digitalSourceType != null) _shortC2paValue(action.digitalSourceType!)].join(' · ')}',
              copyAllText:
                  '${_friendlyC2paAction(action.action)}\n${<String>[if (action.softwareAgent != null) action.softwareAgent!, if (action.digitalSourceType != null) _shortC2paValue(action.digitalSourceType!)].join(' · ')}',
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
        ),
      ],
    );
  }
}

class _C2paHistoryTree extends StatefulWidget {
  const _C2paHistoryTree({
    required this.clip,
    required this.report,
    this.onZoomModeChanged,
  });

  final VideoClipInfo clip;
  final C2paReport? report;
  // Notifies parent of zoom mode changes so it can adjust TabBarView physics.
  final void Function(_ZoomMode mode)? onZoomModeChanged;

  @override
  State<_C2paHistoryTree> createState() => _C2paHistoryTreeState();
}

enum _ZoomMode { fit, oneToOne, free }

class _C2paHistoryTreeState extends State<_C2paHistoryTree> {
  final TransformationController _transformationController =
      TransformationController();

  _ZoomMode _zoomMode = _ZoomMode.fit;
  Size _viewportSize = Size.zero;
  Size _treeSize = Size.zero;
  bool _fitScheduled = false;
  bool _isCanvasGrabbed = false;

  static const double _minScale = 0.15;
  static const double _maxScale = 3.0;
  static const double _scaleStep = 0.25;

  @override
  void initState() {
    super.initState();
    // Apply fit after first frame when sizes are known.
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyMode());
  }

  @override
  void didUpdateWidget(_C2paHistoryTree old) {
    super.didUpdateWidget(old);
    if (old.clip.path != widget.clip.path ||
        old.report?.activeManifestLabel != widget.report?.activeManifestLabel) {
      // New file — re-apply mode after layout settles.
      WidgetsBinding.instance.addPostFrameCallback((_) => _applyMode());
    }
  }

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  double get _currentScale =>
      _transformationController.value.getMaxScaleOnAxis();

  void _applyMode() {
    switch (_zoomMode) {
      case _ZoomMode.fit:
        _fitToView();
      case _ZoomMode.oneToOne:
        _resetZoom();
      case _ZoomMode.free:
        break;
    }
  }

  void _scheduleFitToView() {
    if (_fitScheduled) return;
    _fitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fitScheduled = false;
      if (mounted && _zoomMode == _ZoomMode.fit) _fitToView();
    });
  }

  void _setCanvasGrabbed(bool grabbed) {
    if (_isCanvasGrabbed != grabbed) {
      setState(() => _isCanvasGrabbed = grabbed);
    }
  }

  void _setMode(_ZoomMode mode) {
    setState(() => _zoomMode = mode);
    widget.onZoomModeChanged?.call(mode);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      switch (mode) {
        case _ZoomMode.fit:
          _fitToView();
        case _ZoomMode.oneToOne:
          _resetZoom();
        case _ZoomMode.free:
          break;
      }
    });
  }

  void _zoomTo(double newScale) {
    final clamped = newScale.clamp(_minScale, _maxScale);
    if (_viewportSize == Size.zero) {
      _transformationController.value = Matrix4.identity()
        ..scaleByDouble(clamped, clamped, clamped, 1.0);
      return;
    }
    final focal = Offset(_viewportSize.width / 2, _viewportSize.height / 2);
    final inScene = _transformationController.toScene(focal);
    _transformationController.value = Matrix4.identity()
      ..translateByDouble(
        focal.dx - inScene.dx * clamped,
        focal.dy - inScene.dy * clamped,
        0.0,
        1.0,
      )
      ..scaleByDouble(clamped, clamped, clamped, 1.0);
  }

  void _zoomIn() {
    setState(() => _zoomMode = _ZoomMode.free);
    _zoomTo(_currentScale + _scaleStep);
  }

  void _zoomOut() {
    setState(() => _zoomMode = _ZoomMode.free);
    _zoomTo(_currentScale - _scaleStep);
  }

  void _resetZoom() => _transformationController.value = Matrix4.identity();

  void _fitToView() {
    if (_viewportSize == Size.zero || _treeSize == Size.zero) return;
    const padding = EdgeInsets.fromLTRB(16, 18, 24, 24);
    final contentW = _treeSize.width + padding.horizontal;
    final contentH = _treeSize.height + padding.vertical;
    final fitScale = math
        .min(_viewportSize.width / contentW, _viewportSize.height / contentH)
        .clamp(_minScale, _maxScale);
    final tx = (_viewportSize.width - contentW * fitScale) / 2;
    final ty = (_viewportSize.height - contentH * fitScale) / 2;
    _transformationController.value = Matrix4.identity()
      ..translateByDouble(tx, ty, 0.0, 1.0)
      ..scaleByDouble(fitScale, fitScale, fitScale, 1.0);
  }

  Widget _buildZoomControls() {
    return Container(
      decoration: BoxDecoration(
        color: _c2paPanelBackground.withAlpha(230),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _c2paCardBorder),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _ZoomIconButton(
            icon: Icons.add,
            tooltip: 'Zoom in',
            onPressed: _zoomIn,
          ),
          _ZoomSep(),
          _ZoomModeButton(
            label: 'fit',
            tooltip: 'Fit to view',
            active: _zoomMode == _ZoomMode.fit,
            onPressed: () => _setMode(_ZoomMode.fit),
          ),
          _ZoomSep(),
          _ZoomModeButton(
            label: '1:1',
            tooltip: '100% zoom',
            active: _zoomMode == _ZoomMode.oneToOne,
            onPressed: () => _setMode(_ZoomMode.oneToOne),
          ),
          _ZoomSep(),
          _ZoomModeButton(
            label: 'free',
            tooltip: 'Free pan/zoom',
            active: _zoomMode == _ZoomMode.free,
            onPressed: () => _setMode(_ZoomMode.free),
          ),
          _ZoomSep(),
          _ZoomIconButton(
            icon: Icons.remove,
            tooltip: 'Zoom out',
            onPressed: _zoomOut,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final report = widget.report; // promote to non-nullable via flow analysis
    if (report == null) {
      return const _C2paTabEmptyState(
        icon: Icons.account_tree_outlined,
        message: 'No provenance history',
        subtitle: 'This file has no Content Credentials.',
      );
    }
    final root = report.activeManifest;
    if (root == null) {
      return const Center(child: Text('No manifest history found.'));
    }
    final manifestMap = <String, C2paManifest>{
      for (final item in report.manifests) item.label: item,
    };
    final nodes = _buildC2paTreeNodes(
      root,
      manifestMap,
      report.activeManifestLabel,
      'Untitled asset',
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
            padding: const EdgeInsets.fromLTRB(12, _c2paSectionGap, 12, 12),
            child: DecoratedBox(
              key: const ValueKey<String>('c2pa-history-panel'),
              decoration: BoxDecoration(
                color: _c2paPanelBackground,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: _c2paCardBorder),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(17),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final viewportSize = constraints.biggest;
                    final treeWidth = math.max(
                      constraints.maxWidth,
                      widestLevel * 264.0,
                    );
                    final treeSize = Size(treeWidth, treeHeight);
                    final layoutChanged =
                        _viewportSize != viewportSize || _treeSize != treeSize;
                    _viewportSize = viewportSize;
                    _treeSize = treeSize;
                    if (_zoomMode == _ZoomMode.fit && layoutChanged) {
                      _scheduleFitToView();
                    }
                    return Stack(
                      children: <Widget>[
                        GestureDetector(
                          // Double-tap resets to fit. Uses onDoubleTap only
                          // (no onTap) so there is zero delay on single
                          // pointer-down events — pan sensitivity unchanged.
                          onDoubleTap: () => _setMode(_ZoomMode.fit),
                          child: Listener(
                            onPointerDown: (_) => _setCanvasGrabbed(true),
                            onPointerUp: (_) => _setCanvasGrabbed(false),
                            onPointerCancel: (_) => _setCanvasGrabbed(false),
                            child: MouseRegion(
                              key: const ValueKey<String>(
                                'c2pa-history-pan-region',
                              ),
                              cursor: _isCanvasGrabbed
                                  ? SystemMouseCursors.grabbing
                                  : SystemMouseCursors.grab,
                              child: InteractiveViewer(
                                key: const ValueKey<String>(
                                  'c2pa-history-viewer',
                                ),
                                transformationController:
                                    _transformationController,
                                boundaryMargin: const EdgeInsets.all(
                                  double.infinity,
                                ),
                                minScale: _minScale,
                                maxScale: _maxScale,
                                constrained: false,
                                onInteractionStart: (_) {
                                  if (_zoomMode != _ZoomMode.free) {
                                    setState(() => _zoomMode = _ZoomMode.free);
                                    widget.onZoomModeChanged?.call(
                                      _ZoomMode.free,
                                    );
                                  }
                                },
                                onInteractionEnd: (_) =>
                                    _setCanvasGrabbed(false),
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    18,
                                    24,
                                    24,
                                  ),
                                  child: SizedBox(
                                    width: treeWidth,
                                    height: treeHeight,
                                    child: _C2paTreeCanvas(nodes: nodes),
                                  ),
                                ),
                              ),
                            ),
                          ), // closes Listener
                        ), // closes GestureDetector
                        Positioned(
                          top: 12,
                          right: 12,
                          child: _buildZoomControls(),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        SizedBox(height: MediaQuery.paddingOf(context).bottom),
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
            // Expanded fills remaining height so the Column never overflows,
            // regardless of font metrics differences across platforms.
            Expanded(
              child: Stack(
                fit: StackFit.expand,
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
    // No AspectRatio – the parent Expanded/Stack controls height.
    // BoxFit.contain shows the full image without cropping (center inside).
    return ClipRRect(
      key: const ValueKey<String>('c2pa-tree-thumbnail'),
      borderRadius: BorderRadius.circular(10),
      child: ColoredBox(
        color: const Color(0xFF171A21),
        child: path == null
            ? _fallback()
            : Image.file(
                File(path!),
                fit: BoxFit.contain,
                width: double.infinity,
                height: double.infinity,
                errorBuilder: (_, _, _) => _fallback(),
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

enum _C2paJsonViewMode { tree, raw }

class _C2paTechnicalView extends StatefulWidget {
  const _C2paTechnicalView({super.key, required this.report});

  final C2paReport? report;

  @override
  State<_C2paTechnicalView> createState() => _C2paTechnicalViewState();
}

class _C2paTechnicalViewState extends State<_C2paTechnicalView> {
  _C2paJsonViewMode _viewMode = _C2paJsonViewMode.raw;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _contentScrollController = ScrollController();
  final FocusNode _technicalFocusNode = FocusNode();
  final GlobalKey _jsonHeaderKey = GlobalKey();
  final GlobalKey _jsonSectionKey = GlobalKey();
  final GlobalKey _contentViewportKey = GlobalKey();
  final Set<String> _expandedPaths = <String>{r'$'};
  final Set<String> _searchExpandedPaths = <String>{};
  final Set<String> _searchCollapsedPaths = <String>{};
  bool _hasUserChangedJsonExpansion = false;
  String _search = '';
  bool _isSearchOpen = false;
  int _activeMatch = 0;

  List<int> _matchStarts(String source) {
    if (_search.isEmpty) return const <int>[];
    final starts = <int>[];
    var offset = 0;
    final lowerSource = source.toLowerCase();
    final lowerSearch = _search.toLowerCase();
    while (true) {
      final index = lowerSource.indexOf(lowerSearch, offset);
      if (index < 0) break;
      starts.add(index);
      offset = index + lowerSearch.length;
    }
    return starts;
  }

  void _openSearch() {
    if (_isMobile) return;
    if (_isSearchOpen) {
      FocusScope.of(context).requestFocus(_searchFocusNode);
      return;
    }
    setState(() => _isSearchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusScope.of(context).requestFocus(_searchFocusNode);
      // The search panel can be opened by a hotkey while the JSON section is
      // outside the viewport. Bring its header into view before searching so
      // match scrolling has a laid-out target and a usable scroll extent.
      _scheduleJsonHeaderScroll();
    });
  }

  void openSearch() => _openSearch();

  bool get searchIsOpen => _isSearchOpen;

  void restoreKeyboardFocus() {
    if (_isSearchOpen) {
      FocusScope.of(context).requestFocus(_searchFocusNode);
    }
  }

  final FocusNode _searchFocusNode = FocusNode();

  void _closeSearch() {
    _searchController.clear();
    setState(() {
      _isSearchOpen = false;
      _search = '';
      _activeMatch = 0;
    });
    _technicalFocusNode.requestFocus();
  }

  void closeSearch() => _closeSearch();

  void _moveMatch(int delta) {
    final report = widget.report;
    if (report == null) return;
    final matches = _matchStarts(report.rawJson);
    if (matches.isEmpty) return;
    setState(() {
      _activeMatch = (_activeMatch + delta) % matches.length;
      if (_activeMatch < 0) _activeMatch += matches.length;
    });
    final position = matches[_activeMatch];
    _scheduleScrollMatchIntoView(report.rawJson, position);
  }

  RenderObject? _findTextRenderObject(RenderObject root) {
    RenderObject? textRenderObject;

    void visit(RenderObject child) {
      if (textRenderObject != null) return;
      if (child is RenderEditable || child is RenderParagraph) {
        textRenderObject = child;
        return;
      }
      child.visitChildren(visit);
    }

    root.visitChildren(visit);
    return textRenderObject;
  }

  void _scrollMatchIntoView(String source, int position) {
    if (!_contentScrollController.hasClients) return;
    // Tree mode scrolls its active node from _C2paJsonTreeState using the
    // actual node render object. Raw source offsets do not map to tree rows.
    if (_viewMode == _C2paJsonViewMode.tree) return;
    final jsonBox = _jsonSectionKey.currentContext?.findRenderObject();
    final viewportBox = _contentViewportKey.currentContext?.findRenderObject();
    if (jsonBox is! RenderBox || viewportBox is! RenderBox) return;

    // Prefer the actual text render object used by SelectableText. This keeps
    // the scroll position in sync with Flutter's real text wrapping, font
    // metrics, and text scaling instead of estimating it separately.
    double? matchTopGlobal;
    double? matchBottomGlobal;
    final textRenderObject = _viewMode == _C2paJsonViewMode.raw
        ? _findTextRenderObject(jsonBox)
        : null;
    if (textRenderObject != null && _search.isNotEmpty) {
      final selection = TextSelection(
        baseOffset: position,
        extentOffset: position + _search.length,
      );
      final boxes = switch (textRenderObject) {
        RenderEditable editable => editable.getBoxesForSelection(selection),
        RenderParagraph paragraph => paragraph.getBoxesForSelection(selection),
        _ => const <TextBox>[],
      };
      if (boxes.isNotEmpty) {
        final textRenderBox = textRenderObject as RenderBox;
        matchTopGlobal = boxes
            .map((box) => textRenderBox.localToGlobal(Offset(0, box.top)).dy)
            .reduce(math.min);
        matchBottomGlobal = boxes
            .map((box) => textRenderBox.localToGlobal(Offset(0, box.bottom)).dy)
            .reduce(math.max);
      }
    }

    // Keep a layout-based fallback if the platform does not expose the text
    // render object used by SelectableText.
    if (matchTopGlobal == null || matchBottomGlobal == null) {
      final textPainter = TextPainter(
        text: _highlightJson(source, query: _search, activeMatch: _activeMatch),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: math.max(0.0, jsonBox.size.width - 28));
      final caretOffset = textPainter.getOffsetForCaret(
        TextPosition(offset: position),
        Rect.zero,
      );
      final jsonTop = jsonBox.localToGlobal(Offset.zero).dy;
      matchTopGlobal = jsonTop + 14 + caretOffset.dy;
      matchBottomGlobal = matchTopGlobal + textPainter.preferredLineHeight;
    }

    final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
    final matchTop = matchTopGlobal - viewportTop;
    final matchBottom = matchBottomGlobal - viewportTop;
    const safeTop = 12.0;
    const safeBottom = 12.0;
    final viewportHeight = viewportBox.size.height;
    var targetOffset = _contentScrollController.offset;
    if (matchTop < safeTop) {
      targetOffset += matchTop - safeTop;
    } else if (matchBottom > viewportHeight - safeBottom) {
      targetOffset += matchBottom - (viewportHeight - safeBottom);
    } else {
      return;
    }
    _contentScrollController.jumpTo(
      targetOffset.clamp(
        0.0,
        _contentScrollController.position.maxScrollExtent,
      ),
    );
  }

  void _scheduleJsonHeaderScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final headerContext = _jsonHeaderKey.currentContext;
      final headerBox = headerContext?.findRenderObject();
      final viewportBox = _contentViewportKey.currentContext
          ?.findRenderObject();
      if (headerBox is! RenderBox || viewportBox is! RenderBox) return;
      if (!_contentScrollController.hasClients) return;

      final headerTop = headerBox.localToGlobal(Offset.zero).dy;
      final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
      final targetOffset =
          _contentScrollController.offset + (headerTop - viewportTop) - 8;
      _contentScrollController.jumpTo(
        targetOffset.clamp(
          0.0,
          _contentScrollController.position.maxScrollExtent,
        ),
      );
    });
  }

  void _scrollCurrentMatchIntoView() {
    final report = widget.report;
    if (report == null) return;
    final matches = _matchStarts(report.rawJson);
    if (matches.isEmpty) return;
    _scheduleScrollMatchIntoView(report.rawJson, matches[_activeMatch]);
  }

  void _scheduleScrollMatchIntoView(String source, int position) {
    // Wait for the search rebuild and layout before measuring the match.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollMatchIntoView(source, position);
    });
  }

  void moveMatch(int delta) => _moveMatch(delta);

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _contentScrollController.dispose();
    _technicalFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    if (report == null) {
      return const _C2paTabEmptyState(
        icon: Icons.fact_check_outlined,
        message: 'No validation checks',
        subtitle: 'This file has no Content Credentials.',
      );
    }
    final matches = _matchStarts(report.rawJson);
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): _openSearch,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _openSearch,
        const SingleActivator(LogicalKeyboardKey.escape): _closeSearch,
        const SingleActivator(LogicalKeyboardKey.enter): () => _moveMatch(1),
        const SingleActivator(LogicalKeyboardKey.enter, shift: true): () =>
            _moveMatch(-1),
        const SingleActivator(LogicalKeyboardKey.f3): () => _moveMatch(1),
        const SingleActivator(LogicalKeyboardKey.f3, shift: true): () =>
            _moveMatch(-1),
      },
      child: Focus(
        focusNode: _technicalFocusNode,
        autofocus: true,
        child: Stack(
          children: <Widget>[
            SingleChildScrollView(
              key: _contentViewportKey,
              controller: _contentScrollController,
              padding: EdgeInsets.fromLTRB(
                18,
                _c2paSectionGap,
                18,
                18 + MediaQuery.paddingOf(context).bottom,
              ),
              child: Column(
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          'Validation checks',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
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
                    key: _jsonHeaderKey,
                    children: <Widget>[
                      if (!_isMobile)
                        Text(
                          'Manifest',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        )
                      else
                        Expanded(
                          child: Text(
                            'Manifest',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                      if (!_isMobile) ...<Widget>[
                        const SizedBox(width: 20),
                        _C2paJsonModeSwitch(
                          mode: _viewMode,
                          onChanged: (mode) => setState(() => _viewMode = mode),
                        ),
                        const Spacer(),
                      ],
                      if (!_isMobile)
                        TextButton.icon(
                          key: const ValueKey<String>('open-c2pa-search'),
                          onPressed: _isSearchOpen ? _closeSearch : _openSearch,
                          icon: Icon(
                            _isSearchOpen ? Icons.close : Icons.search,
                            size: 17,
                          ),
                          label: const Text('Search'),
                        ),
                      TextButton.icon(
                        key: const ValueKey<String>('copy-c2pa-json'),
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(text: report.rawJson),
                          );
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
                  SizedBox(
                    key: _jsonSectionKey,
                    width: double.infinity,
                    child: !_isMobile && _viewMode == _C2paJsonViewMode.tree
                        ? SelectionArea(
                            child: _C2paJsonTree(
                              source: report.rawJson,
                              search: _search,
                              activeMatch: _activeMatch,
                              expandedPaths: _expandedPaths,
                              expandAllByDefault: !_hasUserChangedJsonExpansion,
                              searchExpandedPaths: _searchExpandedPaths,
                              searchCollapsedPaths: _searchCollapsedPaths,
                              onToggle: (path, isExpanded) => setState(() {
                                _hasUserChangedJsonExpansion = true;
                                if (_search.isNotEmpty) {
                                  if (isExpanded) {
                                    _searchExpandedPaths.remove(path);
                                    _searchCollapsedPaths.add(path);
                                  } else {
                                    _searchCollapsedPaths.remove(path);
                                    _searchExpandedPaths.add(path);
                                  }
                                } else if (!_expandedPaths.add(path)) {
                                  _expandedPaths.remove(path);
                                }
                              }),
                              onExpandAll: (paths) => setState(() {
                                _hasUserChangedJsonExpansion = true;
                                if (_search.isNotEmpty) {
                                  _searchCollapsedPaths.clear();
                                  _searchExpandedPaths.addAll(paths);
                                }
                                _expandedPaths.addAll(paths);
                              }),
                              onCollapseAll: (paths) => setState(() {
                                _hasUserChangedJsonExpansion = true;
                                if (_search.isNotEmpty) {
                                  _searchExpandedPaths.clear();
                                  _searchCollapsedPaths.addAll(paths);
                                }
                                _expandedPaths.removeWhere(
                                  (path) => path != r'$',
                                );
                              }),
                            ),
                          )
                        : Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF8FAFC),
                              border: Border.all(color: _c2paCardBorder),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: SelectableText.rich(
                              _highlightJson(
                                report.rawJson,
                                query: _search,
                                activeMatch: _activeMatch,
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
            if (!_isMobile && _isSearchOpen)
              Positioned(
                top: 12,
                right: 18,
                child: _C2paSearchPanel(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  matchCount: matches.length,
                  activeMatch: _activeMatch,
                  onChanged: (value) => setState(() {
                    _search = value;
                    _activeMatch = 0;
                    _searchExpandedPaths.clear();
                    _searchCollapsedPaths.clear();
                    _scrollCurrentMatchIntoView();
                  }),
                  onPrevious: () => _moveMatch(-1),
                  onNext: () => _moveMatch(1),
                  onClose: _closeSearch,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _C2paSearchPanel extends StatelessWidget {
  const _C2paSearchPanel({
    required this.controller,
    required this.focusNode,
    required this.matchCount,
    required this.activeMatch,
    required this.onChanged,
    required this.onPrevious,
    required this.onNext,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final int matchCount;
  final int activeMatch;
  final ValueChanged<String> onChanged;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.enter): onNext,
      const SingleActivator(LogicalKeyboardKey.enter, shift: true): onPrevious,
      const SingleActivator(LogicalKeyboardKey.f3): onNext,
      const SingleActivator(LogicalKeyboardKey.f3, shift: true): onPrevious,
    },
    child: Material(
      elevation: 5,
      borderRadius: BorderRadius.circular(10),
      color: Colors.white,
      child: Container(
        width: 360,
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          border: Border.all(color: _c2paCardBorder),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  const Icon(Icons.search, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: const ValueKey<String>('c2pa-search-field'),
                      controller: controller,
                      focusNode: focusNode,
                      autofocus: true,
                      onChanged: onChanged,
                      maxLines: 1,
                      minLines: 1,
                      style: const TextStyle(fontSize: 14),
                      scrollPadding: EdgeInsets.zero,
                      decoration: const InputDecoration(
                        isCollapsed: true,
                        hintText: 'Search',
                        hintStyle: TextStyle(color: Color(0x80697180)),
                        contentPadding: EdgeInsets.zero,
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Text(matchCount == 0 ? '0/0' : '${activeMatch + 1}/$matchCount'),
            const SizedBox(width: 6),
            IconButton(
              tooltip: 'Previous match',
              onPressed: matchCount == 0 ? null : onPrevious,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 34, height: 34),
              icon: const Icon(Icons.keyboard_arrow_up, size: 19),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Next match',
              onPressed: matchCount == 0 ? null : onNext,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 34, height: 34),
              icon: const Icon(Icons.keyboard_arrow_down, size: 19),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Close search',
              onPressed: onClose,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 34, height: 34),
              icon: const Icon(Icons.close, size: 19),
            ),
          ],
        ),
      ),
    ),
  );
}

class _C2paJsonModeSwitch extends StatelessWidget {
  const _C2paJsonModeSwitch({required this.mode, required this.onChanged});

  final _C2paJsonViewMode mode;
  final ValueChanged<_C2paJsonViewMode> onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<_C2paJsonViewMode>(
    key: const ValueKey<String>('c2pa-json-view-mode'),
    segments: const <ButtonSegment<_C2paJsonViewMode>>[
      ButtonSegment(value: _C2paJsonViewMode.raw, label: Text('Raw')),
      ButtonSegment(value: _C2paJsonViewMode.tree, label: Text('Tree')),
    ],
    selected: <_C2paJsonViewMode>{mode},
    onSelectionChanged: (selection) => onChanged(selection.first),
    showSelectedIcon: false,
    style: const ButtonStyle(
      visualDensity: VisualDensity(horizontal: -2, vertical: -3),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      minimumSize: WidgetStatePropertyAll<Size>(Size(0, 28)),
      padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(horizontal: 8),
      ),
      textStyle: WidgetStatePropertyAll<TextStyle>(
        TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    ),
  );
}

class _C2paJsonTree extends StatefulWidget {
  const _C2paJsonTree({
    required this.source,
    required this.search,
    required this.activeMatch,
    required this.expandedPaths,
    required this.expandAllByDefault,
    required this.searchExpandedPaths,
    required this.searchCollapsedPaths,
    required this.onToggle,
    required this.onExpandAll,
    required this.onCollapseAll,
  });

  final String source;
  final String search;
  final int activeMatch;
  final Set<String> expandedPaths;
  final bool expandAllByDefault;
  final void Function(String path, bool isExpanded) onToggle;
  final Set<String> searchExpandedPaths;
  final Set<String> searchCollapsedPaths;
  final ValueChanged<Set<String>> onExpandAll;
  final ValueChanged<Set<String>> onCollapseAll;

  @override
  State<_C2paJsonTree> createState() => _C2paJsonTreeState();
}

class _C2paJsonTreeState extends State<_C2paJsonTree> {
  _C2paJsonNode? _root;
  Set<String> _containerPaths = <String>{};
  String? _parseError;
  final Map<String, GlobalKey> _nodeKeys = <String, GlobalKey>{};
  String? _lastEnsuredActivePath;

  String get source => widget.source;
  String get search => widget.search;
  Set<String> get expandedPaths => widget.expandedPaths;
  bool get expandAllByDefault => widget.expandAllByDefault;
  Set<String> get searchExpandedPaths => widget.searchExpandedPaths;
  Set<String> get searchCollapsedPaths => widget.searchCollapsedPaths;
  void Function(String path, bool isExpanded) get onToggle => widget.onToggle;
  ValueChanged<Set<String>> get onExpandAll => widget.onExpandAll;
  ValueChanged<Set<String>> get onCollapseAll => widget.onCollapseAll;

  GlobalKey _nodeKeyForPath(String path) => _nodeKeys.putIfAbsent(
    path,
    () => GlobalKey(debugLabel: 'c2pa-json-node-$path'),
  );

  void _ensureActiveNodeVisible(String? activePath) {
    if (activePath == _lastEnsuredActivePath) return;
    _lastEnsuredActivePath = activePath;
    if (activePath == null) return;
    final nodeKey = _nodeKeyForPath(activePath);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final nodeContext = nodeKey.currentContext;
      if (nodeContext == null) return;
      Scrollable.ensureVisible(
        nodeContext,
        alignment: 0.35,
        duration: Duration.zero,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
      );
    });
  }

  @override
  void initState() {
    super.initState();
    _parseSource();
  }

  @override
  void didUpdateWidget(_C2paJsonTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) _parseSource();
  }

  void _parseSource() {
    try {
      final decoded = jsonDecode(source);
      final root = _C2paJsonNode.fromValue(decoded, r'$');
      _root = root;
      _containerPaths = root.containerPaths;
      _parseError = null;
    } catch (_) {
      _root = null;
      _containerPaths = <String>{};
      _parseError = 'The manifest is not valid JSON.';
    }
  }

  Set<String> _matchingPaths(_C2paJsonNode root, String query) {
    if (query.isEmpty) return const <String>{};
    final normalizedQuery = query.toLowerCase();
    final matchingPaths = <String>{};

    bool visit(_C2paJsonNode node) {
      final directMatch = _jsonSearchText(
        node,
      ).toLowerCase().contains(normalizedQuery);
      var descendantMatch = false;
      for (final child in node.children) {
        if (visit(child)) descendantMatch = true;
      }
      final matched = directMatch || descendantMatch;
      if (matched) matchingPaths.add(node.path);
      return matched;
    }

    visit(root);
    return matchingPaths;
  }

  List<String> _directMatchingPaths(_C2paJsonNode root, String query) {
    if (query.isEmpty) return const <String>[];
    final normalizedQuery = query.toLowerCase();
    final paths = <String>[];
    void visit(_C2paJsonNode node) {
      if (_jsonSearchText(node).toLowerCase().contains(normalizedQuery)) {
        paths.add(node.path);
      }
      for (final child in node.children) {
        visit(child);
      }
    }

    visit(root);
    return paths;
  }

  @override
  Widget build(BuildContext context) {
    final root = _root;
    if (root == null) {
      return _C2paJsonError(message: _parseError!);
    }
    final topLevelNodes = root.children.isEmpty
        ? <_C2paJsonNode>[root]
        : root.children;
    final matchingPaths = _matchingPaths(root, search);
    final directMatchingPaths = _directMatchingPaths(root, search);
    final activePath = directMatchingPaths.isEmpty
        ? null
        : directMatchingPaths[widget.activeMatch % directMatchingPaths.length];
    _ensureActiveNodeVisible(activePath);
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        border: Border.all(color: _c2paCardBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final actions = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    TextButton.icon(
                      key: const ValueKey<String>('c2pa-json-expand-all'),
                      onPressed: () => onExpandAll(_containerPaths),
                      icon: const Icon(Icons.unfold_more, size: 17),
                      label: const Text('Expand all'),
                    ),
                    const SizedBox(width: 18),
                    TextButton.icon(
                      key: const ValueKey<String>('c2pa-json-collapse-all'),
                      onPressed: () => onCollapseAll(_containerPaths),
                      icon: const Icon(Icons.unfold_less, size: 17),
                      label: const Text('Collapse all'),
                    ),
                  ],
                );
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[Expanded(child: actions)],
                );
              },
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
            child: SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: topLevelNodes
                    .map(
                      (node) => _C2paJsonNodeView(
                        node: node,
                        depth: 0,
                        search: search,
                        matchingPaths: matchingPaths,
                        activePath: activePath,
                        expandedPaths: expandedPaths,
                        expandAllByDefault: expandAllByDefault,
                        searchExpandedPaths: searchExpandedPaths,
                        searchCollapsedPaths: searchCollapsedPaths,
                        onToggle: onToggle,
                        nodeKeyForPath: _nodeKeyForPath,
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _C2paJsonError extends StatelessWidget {
  const _C2paJsonError({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(18),
    child: Text(message, style: const TextStyle(color: _c2paMutedText)),
  );
}

class _C2paJsonNode {
  _C2paJsonNode({required this.label, required this.value, required this.path});

  factory _C2paJsonNode.fromValue(dynamic value, String path, {String? label}) {
    final node = _C2paJsonNode(label: label, value: value, path: path);
    if (value is Map) {
      node.children = value.entries
          .map(
            (entry) => _C2paJsonNode.fromValue(
              entry.value,
              '$path.${entry.key}',
              label: '${entry.key}',
            ),
          )
          .toList();
    } else if (value is List) {
      node.children = value
          .asMap()
          .entries
          .map(
            (entry) => _C2paJsonNode.fromValue(
              entry.value,
              '$path[${entry.key}]',
              label: '${entry.key}',
            ),
          )
          .toList();
    }
    return node;
  }

  final String? label;
  final dynamic value;
  final String path;
  List<_C2paJsonNode> children = <_C2paJsonNode>[];

  bool get isContainer => children.isNotEmpty || value is Map || value is List;

  late final Set<String> containerPaths = <String>{
    if (isContainer) path,
    for (final child in children) ...child.containerPaths,
  };

  String get typeLabel => value is Map
      ? 'Object (${children.length} ${children.length == 1 ? 'key' : 'keys'})'
      : 'Array (${children.length} ${children.length == 1 ? 'item' : 'items'})';
}

String _jsonSearchText(_C2paJsonNode node) =>
    '${node.label ?? ''} ${node.isContainer ? node.typeLabel : _valueText(node.value)}';

class _C2paJsonNodeView extends StatelessWidget {
  const _C2paJsonNodeView({
    required this.node,
    required this.depth,
    required this.search,
    required this.matchingPaths,
    required this.activePath,
    required this.expandedPaths,
    required this.expandAllByDefault,
    required this.searchExpandedPaths,
    required this.searchCollapsedPaths,
    required this.onToggle,
    required this.nodeKeyForPath,
  });

  final _C2paJsonNode node;
  final int depth;
  final String search;
  final Set<String> matchingPaths;
  final String? activePath;
  final Set<String> expandedPaths;
  final bool expandAllByDefault;
  final Set<String> searchExpandedPaths;
  final Set<String> searchCollapsedPaths;
  final void Function(String path, bool isExpanded) onToggle;
  final GlobalKey Function(String path) nodeKeyForPath;

  @override
  Widget build(BuildContext context) {
    final isExpanded = search.isNotEmpty
        ? searchCollapsedPaths.contains(node.path)
              ? false
              : searchExpandedPaths.contains(node.path) ||
                    matchingPaths.contains(node.path)
        : expandAllByDefault || expandedPaths.contains(node.path);
    final children = node.children;
    final hasChildren = node.isContainer;
    final keySpan = _highlightJsonFragment(
      node.label == null ? r'$ ' : '${node.label}: ',
      search,
      _c2paJsonKeyStyle,
      active: node.path == activePath,
    );
    final valueSpan = _highlightJsonFragment(
      hasChildren ? node.typeLabel : _valueText(node.value),
      search,
      hasChildren ? _c2paJsonTypeStyle : _c2paJsonValueStyle(node.value),
      active: node.path == activePath,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InkWell(
          key: nodeKeyForPath(node.path),
          onTap: hasChildren ? () => onToggle(node.path, isExpanded) : null,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: EdgeInsets.only(left: depth * 16.0, top: 3, bottom: 3),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 18,
                  child: hasChildren
                      ? Icon(
                          isExpanded
                              ? Icons.keyboard_arrow_down
                              : Icons.chevron_right,
                          size: 16,
                          color: _c2paMutedText,
                        )
                      : null,
                ),
                if (_isMobile) ...<Widget>[
                  Expanded(
                    flex: 5,
                    child: Text.rich(keySpan, overflow: TextOverflow.ellipsis),
                  ),
                  Expanded(
                    flex: 6,
                    child: Text.rich(
                      valueSpan,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ] else ...<Widget>[
                  Text.rich(keySpan),
                  Flexible(
                    child: Text.rich(
                      valueSpan,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (hasChildren && isExpanded)
          ...children.map(
            (child) => _C2paJsonNodeView(
              node: child,
              depth: depth + 1,
              search: search,
              matchingPaths: matchingPaths,
              activePath: activePath,
              expandedPaths: expandedPaths,
              expandAllByDefault: expandAllByDefault,
              searchExpandedPaths: searchExpandedPaths,
              searchCollapsedPaths: searchCollapsedPaths,
              onToggle: onToggle,
              nodeKeyForPath: nodeKeyForPath,
            ),
          ),
      ],
    );
  }
}

String _valueText(dynamic value) {
  if (value == null) return 'null';
  if (value is String) return '"$value"';
  return '$value';
}

final String _c2paJsonFontFamily = Platform.isIOS || Platform.isMacOS
    ? 'Menlo'
    : 'monospace';
final TextStyle _c2paJsonKeyStyle = TextStyle(
  fontFamily: _c2paJsonFontFamily,
  fontFamilyFallback: const <String>['SF Mono', 'Roboto Mono', 'Courier New'],
  color: Color(0xFF20242C),
  fontSize: 12,
  height: 1.2,
);
final TextStyle _c2paJsonTypeStyle = TextStyle(
  fontFamily: _c2paJsonFontFamily,
  fontFamilyFallback: const <String>['SF Mono', 'Roboto Mono', 'Courier New'],
  color: _c2paMutedText,
  fontSize: 12,
  height: 1.2,
);
final TextStyle _c2paJsonStringStyle = TextStyle(
  fontFamily: _c2paJsonFontFamily,
  fontFamilyFallback: const <String>['SF Mono', 'Roboto Mono', 'Courier New'],
  color: const Color(0xFF168A58),
  fontSize: 12,
  height: 1.2,
);
final TextStyle _c2paJsonNumberStyle = TextStyle(
  fontFamily: _c2paJsonFontFamily,
  fontFamilyFallback: const <String>['SF Mono', 'Roboto Mono', 'Courier New'],
  color: const Color(0xFFB14D2D),
  fontSize: 12,
  height: 1.2,
);
TextStyle _c2paJsonValueStyle(dynamic value) =>
    value is String ? _c2paJsonStringStyle : _c2paJsonNumberStyle;

TextSpan _highlightJsonFragment(
  String text,
  String query,
  TextStyle baseStyle, {
  bool active = false,
}) {
  if (query.isEmpty) return TextSpan(text: text, style: baseStyle);
  final spans = <InlineSpan>[];
  final lowerText = text.toLowerCase();
  final lowerQuery = query.toLowerCase();
  var offset = 0;
  while (true) {
    final matchStart = lowerText.indexOf(lowerQuery, offset);
    if (matchStart < 0) {
      if (offset < text.length) {
        spans.add(TextSpan(text: text.substring(offset)));
      }
      break;
    }
    if (matchStart > offset) {
      spans.add(TextSpan(text: text.substring(offset, matchStart)));
    }
    spans.add(
      TextSpan(
        text: text.substring(matchStart, matchStart + query.length),
        style: baseStyle.copyWith(
          backgroundColor: active
              ? const Color(0xFFFFA726)
              : const Color(0xFFFFE36E),
          color: const Color(0xFF20242C),
        ),
      ),
    );
    offset = matchStart + query.length;
  }
  return TextSpan(style: baseStyle, children: spans);
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
      child: _C2paCopySelectionArea(
        rawAllText: '${entry.code}${entry.explanation ?? ''}',
        copyAllText: '${entry.code}\n${entry.explanation ?? ''}',
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
      ),
    );
  }
}

TextSpan _highlightJson(
  String source, {
  String query = '',
  int activeMatch = 0,
}) {
  final baseStyle = TextStyle(
    fontFamily: Platform.isIOS || Platform.isMacOS ? 'Menlo' : 'monospace',
    fontFamilyFallback: const <String>['SF Mono', 'Roboto Mono', 'Courier New'],
    fontSize: 11.5,
    fontWeight: FontWeight.w500,
    color: const Color(0xFF475569),
    height: 1.55,
  );
  if (query.isNotEmpty) {
    final spans = <InlineSpan>[];
    final lowerSource = source.toLowerCase();
    final lowerQuery = query.toLowerCase();
    var offset = 0;
    var matchIndex = 0;
    while (true) {
      final start = lowerSource.indexOf(lowerQuery, offset);
      if (start < 0) break;
      if (start > offset) {
        spans.add(TextSpan(text: source.substring(offset, start)));
      }
      spans.add(
        TextSpan(
          text: source.substring(start, start + query.length),
          style: baseStyle.copyWith(
            backgroundColor: matchIndex == activeMatch
                ? const Color(0xFFFFA726)
                : const Color(0xFFFFE36E),
            color: const Color(0xFF20242C),
          ),
        ),
      );
      matchIndex++;
      offset = start + query.length;
    }
    if (offset < source.length) {
      spans.add(TextSpan(text: source.substring(offset)));
    }
    return TextSpan(style: baseStyle, children: spans);
  }
  const keyStyle = TextStyle(color: Color(0xFF2563EB));
  const stringStyle = TextStyle(color: Color(0xFF15803D));
  const numberStyle = TextStyle(color: Color(0xFFB45309));
  const literalStyle = TextStyle(color: Color(0xFF7C3AED));
  const punctuationStyle = TextStyle(color: Color(0xFF64748B));
  final tokenPattern = RegExp(
    r'"(?:\\.|[^"\\])*"|true|false|null|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|[{}\[\],:]',
  );
  final spans = <InlineSpan>[];
  var offset = 0;
  for (final match in tokenPattern.allMatches(source)) {
    if (match.start > offset) {
      spans.add(TextSpan(text: source.substring(offset, match.start)));
    }
    final token = match.group(0)!;
    final style = token.startsWith('"')
        ? RegExp(r'^\s*:').hasMatch(source.substring(match.end))
              ? keyStyle
              : stringStyle
        : token == 'true' || token == 'false' || token == 'null'
        ? literalStyle
        : RegExp(r'^-?\d').hasMatch(token)
        ? numberStyle
        : punctuationStyle;
    spans.add(TextSpan(text: token, style: style));
    offset = match.end;
  }
  if (offset < source.length) {
    spans.add(TextSpan(text: source.substring(offset)));
  }
  return TextSpan(style: baseStyle, children: spans);
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

// ── Zoom control widgets ─────────────────────────────────────────────────────

// ── Zoom control widgets ─────────────────────────────────────────────────────

class _ZoomIconButton extends StatelessWidget {
  const _ZoomIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 16, color: _c2paMutedText),
        ),
      ),
    );
  }
}

class _ZoomModeButton extends StatelessWidget {
  const _ZoomModeButton({
    required this.label,
    required this.tooltip,
    required this.active,
    required this.onPressed,
  });

  final String label;
  final String tooltip;
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: active ? _c2paAccent.withAlpha(26) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? _c2paAccent : _c2paMutedText,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

class _ZoomSep extends StatelessWidget {
  const _ZoomSep();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 20,
      child: VerticalDivider(width: 1, thickness: 1, color: _c2paCardBorder),
    );
  }
}
