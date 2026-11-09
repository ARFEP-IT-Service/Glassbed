import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/device.dart';
import '../../core/discovery.dart';
import '../../core/edit.dart' show Edits;
import '../../core/escl.dart';
import '../../core/export.dart';
import '../../core/ipp.dart';
import '../../i18n.dart';
import '../../platform.dart';
import '../dialogs.dart';
import '../editor/editor_screen.dart';
import '../image_work.dart';
import '../page_item.dart';
import '../settings_screen.dart';
import 'pages_grid.dart';
import 'printer_card.dart';
import 'save_sheet.dart';
import 'scan_card.dart';

const _prefHost = 'last_host';
const _prefSource = 'scan_source';
const _prefMode = 'scan_mode';
const _prefDpi = 'scan_dpi';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _host = TextEditingController();

  // Printer
  List<Device>? _found;
  bool _searching = false;
  Device? _device;
  EsclClient? _escl;
  ScannerCaps? _caps;
  PrinterInfo? _info;
  Link _link = Link.none;
  int _connectGeneration = 0;

  // Scan options
  ScanSource _source = ScanSource.platen;
  ColorMode _mode = ColorMode.color;
  int _dpi = 200;

  // Scanning
  CancelToken? _cancel;
  int _pagesThisRun = 0;

  // Pages
  final List<PageItem> _pages = [];
  bool _unsaved = false;
  bool _busyExport = false;

  bool get _scanning => _cancel != null;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void dispose() {
    _cancel?.cancel();
    _escl?.close();
    _host.dispose();
    for (final p in _pages) {
      p.dispose();
    }
    super.dispose();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _source = ScanSource.values.asNameMap()[prefs.getString(_prefSource)] ?? _source;
      _mode = ColorMode.values.asNameMap()[prefs.getString(_prefMode)] ?? _mode;
      _dpi = prefs.getInt(_prefDpi) ?? _dpi;
    });
    final host = prefs.getString(_prefHost);
    if (host != null && host.isNotEmpty) {
      _host.text = host;
      // Only reconnect silently if no permission dialog is needed.
      if (await Native.localNetworkAllowed()) _connect(Device.fromHost(host));
    }
  }

  Future<void> _storeOptions() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefSource, _source.name);
    await prefs.setString(_prefMode, _mode.name);
    await prefs.setInt(_prefDpi, _dpi);
  }

  // ---------------------------------------------------------------- printer

  Future<void> _search() async {
    FocusScope.of(context).unfocus();
    if (!await ensureLocalNetwork(context)) return;
    setState(() => _searching = true);
    List<Device> found = const [];
    try {
      await Native.acquireMulticastLock();
      found = await discover();
    } catch (e) {
      if (mounted) showSnack(context, errorText(e, fallback: 'Search failed.'), error: true);
    } finally {
      await Native.releaseMulticastLock();
    }
    if (!mounted) return;
    setState(() {
      _searching = false;
      _found = found;
    });
    // One printer in the network: take it right away.
    if (found.length == 1 && _device?.host != found.first.host) _pick(found.first);
  }

  void _pick(Device d) {
    _host.text = d.host;
    _connect(d);
  }

  Future<void> _connectFromField() async {
    FocusScope.of(context).unfocus();
    final text = _host.text.trim();
    if (text.isEmpty) {
      showSnack(context, tr('No printer selected.'));
      return;
    }
    if (!await ensureLocalNetwork(context)) return;
    // Keep the discovered endpoints if the field still shows a found device.
    final known = _found?.where((d) => d.host == text).firstOrNull;
    await _connect(known ?? Device.fromHost(text));
  }

  Future<void> _connect(Device device) async {
    final generation = ++_connectGeneration;
    _escl?.close();
    setState(() {
      _device = device;
      _escl = EsclClient(device.esclBase);
      _caps = null;
      _info = null;
      _link = Link.connecting;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefHost, device.host);

    Object? error;
    final capsFuture = _escl!.capabilities().then<ScannerCaps?>((c) => c, onError: (Object e) {
      error = e;
      return null;
    });
    final infoFuture = getPrinterInfo(device.ippUri, timeout: const Duration(seconds: 6))
        .then<PrinterInfo?>((i) => i, onError: (Object _) => null);
    final caps = await capsFuture;
    final info = await infoFuture;
    if (!mounted || generation != _connectGeneration) return;
    setState(() {
      _caps = caps;
      _info = info;
      _link = (caps != null || info != null) ? Link.online : Link.offline;
      _fitOptionsToCaps();
    });
    if (caps == null && error != null) {
      showSnack(context, errorText(error!, fallback: 'Could not connect to the printer.'), error: true);
    }
  }

  /// Keeps the chosen options valid for the connected scanner.
  void _fitOptionsToCaps() {
    final sources = availableSources(_caps);
    if (!sources.contains(_source)) _source = sources.first;
    final modes = availableModes(_caps, _source);
    if (!modes.contains(_mode)) _mode = modes.first;
    final res = availableResolutions(_caps, _source);
    if (!res.contains(_dpi)) {
      _dpi = res.contains(200) ? 200 : res.reduce((a, b) => (a - 200).abs() <= (b - 200).abs() ? a : b);
    }
  }

  // ---------------------------------------------------------------- scanning

  Future<void> _scan() async {
    if (_device == null) {
      await _connectFromField();
      if (_device == null || !mounted) return;
    } else if (!await ensureLocalNetwork(context)) {
      return;
    }
    final client = _escl ??= EsclClient(_device!.esclBase);
    final cancel = CancelToken();
    setState(() {
      _cancel = cancel;
      _pagesThisRun = 0;
    });
    try {
      final settings = ScanSettings(source: _source, mode: _mode, dpi: _dpi);
      await for (final page in client.scan(settings, cancel: cancel)) {
        if (!mounted) return;
        final item = PageItem(page);
        setState(() {
          _pages.add(item);
          _pagesThisRun++;
          _unsaved = true;
        });
        item.refreshThumbnail(_thumbReady);
      }
      if (mounted) {
        showSnack(context, tr('{n} page(s) scanned.', {'n': _pagesThisRun}));
      }
    } on ScanCancelled {
      if (mounted) showSnack(context, tr('Scan cancelled.'));
    } on FeederEmpty catch (e) {
      // An empty feeder after some pages simply means "done".
      if (mounted) {
        if (_pagesThisRun > 0) {
          showSnack(context, tr('{n} page(s) scanned.', {'n': _pagesThisRun}));
        } else {
          showSnack(context, errorText(e), error: true);
        }
      }
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _cancel = null);
    }
  }

  void _thumbReady() {
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------- pages

  Future<void> _onPageAction(PageItem page, PageAction action) async {
    switch (action) {
      case PageAction.edit:
        final edits = await Navigator.push<Edits>(
          context,
          MaterialPageRoute(builder: (_) => EditorScreen(page: page)),
        );
        if (edits == null || !mounted) return;
        setState(() {
          page.edits = edits;
          _unsaved = true;
        });
        page.refreshThumbnail(_thumbReady);
      case PageAction.rotateLeft:
      case PageAction.rotateRight:
        final step = action == PageAction.rotateLeft ? 270 : 90;
        setState(() {
          page.edits.rotateBy(step);
          _unsaved = true;
        });
        page.refreshThumbnail(_thumbReady);
      case PageAction.delete:
        setState(() {
          _pages.remove(page);
          if (_pages.isEmpty) _unsaved = false;
        });
        page.dispose();
    }
  }

  void _move(int from, int to) {
    setState(() {
      final p = _pages.removeAt(from);
      _pages.insert(to, p);
      _unsaved = true;
    });
  }

  Future<void> _clearAll() async {
    if (_unsaved &&
        !await confirm(
          context,
          title: tr('Unsaved scans'),
          message: tr('{n} scanned page(s) have not been saved. Remove them anyway?',
              {'n': _pages.length}),
          confirmLabel: tr('Remove all'),
          destructive: true,
        )) {
      return;
    }
    setState(() {
      for (final p in _pages) {
        p.dispose();
      }
      _pages.clear();
      _unsaved = false;
    });
  }

  // ---------------------------------------------------------------- output

  Future<List<ExportedFile>?> _export(SaveOptions o) async {
    setState(() => _busyExport = true);
    try {
      final jobs = [
        for (final p in _pages) (image: p.original, dpi: p.page.dpi, edits: p.edits.copy()),
      ];
      return await exportJobs(jobs, o.format, baseName: o.baseName, splitPdf: o.splitPdf);
    } catch (e) {
      if (mounted) showSnack(context, tr('Could not save'), error: true);
      return null;
    } finally {
      if (mounted) setState(() => _busyExport = false);
    }
  }

  Future<void> _save() async {
    final o = await showSaveSheet(context,
        actionLabel: tr('Save'), actionIcon: Icons.save_alt, pageCount: _pages.length);
    if (o == null || !mounted) return;
    final files = await _export(o);
    if (files == null || !mounted) return;
    try {
      final saved = await Native.saveFiles(files);
      if (!mounted || saved == 0) return;
      setState(() => _unsaved = false);
      showSnack(context, tr('Saved'));
    } on PlatformException {
      if (mounted) showSnack(context, tr('Could not save'), error: true);
    }
  }

  Future<void> _share() async {
    final o = await showSaveSheet(context,
        actionLabel: tr('Share'), actionIcon: Icons.share, pageCount: _pages.length);
    if (o == null || !mounted) return;
    final files = await _export(o);
    if (files == null || !mounted) return;
    final result = await SharePlus.instance.share(ShareParams(
      files: [for (final f in files) XFile.fromData(f.bytes, name: f.name, mimeType: f.mimeType)],
      fileNameOverrides: [for (final f in files) f.name],
    ));
    if (mounted && result.status == ShareResultStatus.success) {
      setState(() => _unsaved = false);
    }
  }

  // ---------------------------------------------------------------- leaving

  Future<void> _onPopBlocked() async {
    final leave = await confirm(
      context,
      title: tr('Unsaved scans'),
      message: tr('{n} scanned page(s) have not been saved. Leave anyway?', {'n': _pages.length}),
      confirmLabel: tr('Discard'),
      destructive: true,
    );
    if (leave && mounted) {
      setState(() => _unsaved = false);
      await SystemNavigator.pop();
    }
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_unsaved || _pages.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onPopBlocked();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              Image.asset('assets/icon/glassbed.png', width: 28, height: 28),
              const SizedBox(width: 10),
              const Text('Glassbed'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: tr('Settings'),
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              PrinterCard(
                hostController: _host,
                searching: _searching,
                devices: _found,
                selected: _device,
                link: _link,
                info: _info,
                onConnect: _connectFromField,
                onSearch: _search,
                onPick: _pick,
              ),
              const SizedBox(height: 12),
              ScanCard(
                caps: _caps,
                source: _source,
                mode: _mode,
                dpi: _dpi,
                scanning: _scanning,
                pagesThisRun: _pagesThisRun,
                hasPages: _pages.isNotEmpty,
                onSource: (v) => setState(() {
                  _source = v;
                  _fitOptionsToCaps();
                  _storeOptions();
                }),
                onMode: (v) => setState(() {
                  _mode = v;
                  _storeOptions();
                }),
                onDpi: (v) => setState(() {
                  _dpi = v;
                  _storeOptions();
                }),
                onScan: _busyExport ? null : _scan,
                onCancel: () => _cancel?.cancel(),
              ),
              if (_pages.isNotEmpty) ...[
                const SizedBox(height: 20),
                Row(
                  children: [
                    Text(tr('Pages'), style: theme.textTheme.titleMedium),
                    const SizedBox(width: 8),
                    Text(tr('{n} page(s)', {'n': _pages.length}),
                        style: theme.textTheme.bodySmall),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _scanning || _busyExport ? null : _clearAll,
                      icon: const Icon(Icons.delete_sweep_outlined),
                      label: Text(tr('Clear all')),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                PagesGrid(pages: _pages, onAction: _onPageAction, onMove: _move),
              ],
            ],
          ),
        ),
        bottomNavigationBar: _pages.isEmpty ? null : _actionBar(),
      ),
    );
  }

  Widget _actionBar() {
    final disabled = _scanning || _busyExport;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
        ),
        child: _busyExport
            ? SizedBox(
                height: 52,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox.square(
                        dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
                    const SizedBox(width: 14),
                    Text(tr('Saving…')),
                  ],
                ),
              )
            : Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 52,
                      child: FilledButton.icon(
                        onPressed: disabled ? null : _save,
                        icon: const Icon(Icons.save_alt),
                        label: Text(tr('Save')),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 52,
                      child: FilledButton.tonalIcon(
                        onPressed: disabled ? null : _share,
                        icon: const Icon(Icons.share),
                        label: Text(tr('Share')),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
