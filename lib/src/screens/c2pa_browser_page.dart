import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
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
    with SingleTickerProviderStateMixin {
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
    _tabController = TabController(length: 3, vsync: this)
      // Rebuild on tab change so TabBarView physics update.
      ..addListener(() { if (mounted) setState(() {}); });
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
    _tabController.dispose();
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
    final mobile = Platform.isIOS || Platform.isAndroid;
    if (mobile) {
      // On mobile, always open Camera Roll via PHPickerViewController so the
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
          _showErrorToast('Saved media with C2PA to Photos.');
        } catch (saveError) {
          _showErrorToast('Could not save to Photos directly, using share sheet instead: $saveError');
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
            child: Stack(
                children: <Widget>[
                  Column(
                    children: <Widget>[
                      _C2paPageHeader(
                        clip: _hasMedia ? _clip : null,
                        onOpen: () => unawaited(_pickMedia()),
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
                          child: IgnorePointer(
                            ignoring: report == null,
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 200),
                              opacity: report == null ? 0.35 : 1.0,
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
                          ),
                        ),
                      if (_hasMedia) ...<Widget>[
                        const SizedBox(height: _c2paSectionGap),
                        _C2paFileLocationBar(path: _clip.path),
                      ],
                      Expanded(
                        child: report != null
                            ? TabBarView(
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
                                  _C2paTechnicalView(report: report),
                                ],
                              )
                            : !_hasMedia
                            ? AnimatedOpacity(
                                duration: const Duration(milliseconds: 140),
                                opacity: _isDragging ? 0 : 1,
                                child: const _C2paAwaitingMediaView(),
                              )
                            : _clip.aiMetadata.c2paStatus == C2paStatus.absent
                            ? _C2paNoCredentialsView(
                                clip: _clip,
                                hideDropPrompt: _isDragging || Platform.isIOS || Platform.isAndroid,
                              )
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
                      top: 0,
                      left: 0,
                      right: 0,
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('Select the C2PA operation to apply.'),
            if (widget.mobileNative) ...const <Widget>[
              SizedBox(height: 8),
              Text('On iOS, the result is saved to Photos.'),
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
                    subtitle: Text('Keep existing C2PA as parent, add a new claim'),
                    contentPadding: EdgeInsets.zero,
                  ),
                  const RadioListTile<C2paWriteMode>(
                    key: ValueKey<String>('c2pa-write-replace'),
                    value: C2paWriteMode.replace,
                    title: Text('Replace C2PA'),
                    subtitle: Text('Discard existing C2PA, write a fresh claim'),
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
                  _createNewFile ? 'Save to a new file and keep the original' : 'Overwrite the current file in place',
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
    return Padding(
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
              'assets/app_icon_1024.png',
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
          IconButton(
            key: const ValueKey<String>('open-media-file'),
            tooltip: 'Open media',
            onPressed: onOpen,
            icon: const Icon(Icons.folder_open_outlined),
          ),
        ],
      ),
    );
  }
}

class _C2paFileLocationBar extends StatelessWidget {
  const _C2paFileLocationBar({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
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
      padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _c2paCardBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.insert_drive_file_outlined,
            size: 20,
            color: _c2paAccentDark,
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
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
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
              Platform.isIOS || Platform.isAndroid
                  ? 'Tap the folder button to inspect a photo'
                  : 'Drop media to inspect Content Credentials',
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
  const _C2paNoCredentialsView({
    required this.clip,
    required this.hideDropPrompt,
  });

  final VideoClipInfo clip;
  final bool hideDropPrompt;

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
      padding: const EdgeInsets.fromLTRB(18, _c2paSectionGap, 18, 18),
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
        const SizedBox(height: 24),
        AnimatedOpacity(
          key: const ValueKey<String>('c2pa-no-credentials-drop-prompt'),
          duration: const Duration(milliseconds: 140),
          opacity: hideDropPrompt ? 0 : 1,
          child: const Center(child: _C2paDropPrompt()),
        ),
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
    final isMobile = Platform.isIOS || Platform.isAndroid;
    // Reusable card widgets (keys must be stable across layouts).
    // shrinkWrap required on mobile: cards live inside ListView (unbounded height).
    final signerCard = _C2paInfoCard(
      key: const ValueKey<String>('c2pa-overview-signer'),
      title: 'Signer',
      icon: Icons.draw_outlined,
      rows: <(String, String?)>[
        ('Issuer', manifest?.issuer ?? manifest?.commonName),
        ('Algorithm', manifest?.algorithm),
        ('Signed', manifest?.signedAt),
        ('App or device', manifest?.claimGenerator),
      ],
      shrinkWrap: isMobile,
    );
    final manifestCard = _C2paInfoCard(
      key: const ValueKey<String>('c2pa-overview-manifest'),
      title: 'Manifest',
      icon: Icons.description_outlined,
      rows: <(String, String?)>[
        ('Title', manifest?.title ?? p.basename(clip.path)),
        (
          'Format',
          manifest?.format ?? shortMediaTypeLabel(clip.path, clip.mediaKind),
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
      shrinkWrap: isMobile,
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, _c2paSectionGap, 18, 18),
      children: <Widget>[
        // Mobile: thumbnail full-width 4:3, info cards stacked below.
        // Desktop: side-by-side row (unchanged).
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
    // shrinkWrap: true when the card is inside an unbounded-height parent
    // (e.g. ListView on mobile). Disables Expanded so the column sizes to
    // its content instead of requiring a finite parent height.
    this.shrinkWrap = false,
  });

  final String title;
  final IconData icon;
  final List<(String, String?)> rows;
  final bool shrinkWrap;

  List<Widget> _buildRows(bool compact) {
    final visibleRows = rows.where((row) => row.$2 != null).toList();
    return <Widget>[
      for (int i = 0; i < visibleRows.length; i++) ...<Widget>[
        if (i > 0) const SizedBox(height: 8),
        if (compact)
          Align(
            alignment: Alignment.centerLeft,
            child: Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(
                    text: '${visibleRows[i].$1}: ',
                    style: const TextStyle(color: _c2paMutedText, fontSize: 11),
                  ),
                  TextSpan(text: visibleRows[i].$2!),
                ],
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          )
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 94,
                child: Text(
                  visibleRows[i].$1,
                  style: const TextStyle(color: _c2paMutedText, fontSize: 12),
                ),
              ),
              Expanded(
                child: Text(
                  visibleRows[i].$2!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
      ],
    ];
  }

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
        mainAxisSize: shrinkWrap ? MainAxisSize.min : MainAxisSize.max,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 19, color: _c2paAccentDark),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
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
                  children: _buildRows(constraints.maxWidth < 240),
                );
              },
            )
          else
            // Bounded context (desktop row): fill remaining height with spaceEvenly.
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 240;
                  return Column(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: _buildRows(compact),
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
  const _C2paHistoryTree({
    required this.clip,
    required this.report,
    this.onZoomModeChanged,
  });

  final VideoClipInfo clip;
  final C2paReport report;
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
        old.report.activeManifestLabel != widget.report.activeManifestLabel) {
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
                                  widget.onZoomModeChanged?.call(_ZoomMode.free);
                                }
                              },
                              onInteractionEnd: (_) => _setCanvasGrabbed(false),
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

class _C2paTechnicalView extends StatelessWidget {
  const _C2paTechnicalView({required this.report});

  final C2paReport report;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, _c2paSectionGap, 18, 18),
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

