import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/app_index.dart';
import '../services/account_store.dart';
import '../services/billing_links.dart';
import '../app_flavor.dart';
import '../services/clip_joint.dart';
import '../services/consent_store.dart';
import '../services/debug_seed.dart';
import '../services/handoff.dart';
import '../services/license_store.dart';
import '../services/media_source.dart';
import '../services/pipeline_benchmark.dart';
import '../services/pro_gate.dart';
import '../services/search_service.dart';
import '../services/stt_indexer.dart';
import '../services/tflite_stt.dart';
import 'folder_picker_screen.dart';
import 'account_setup_screen.dart';
import 'landing_screen.dart';
import 'paywall_sheet.dart';

/// Settings: revoke/rescope folders + telemetry toggle (exit criteria).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _optIn = false;
  bool _benchRunning = false;
  bool _scaleRunning = false;
  String? _scaleProgress;
  bool _videoRunning = false;
  bool _isPro = false;
  bool _phase5Running = false;
  bool _crashOptIn = false;
  bool _autoTranscribe = false;
  bool _rebuilding = false;
  bool _transcribing = false;
  bool _useClip = false;
  bool _isAdmin = false;
  List<AccountProfile> _profiles = const [];
  String? _activeId;
  String _activeName = '';
  String _proUntil = '';

  static String _formatDate(int ms) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  /// PIN prompt controller lives as long as this State: disposing it the
  /// moment a dialog pops crashes the route's exit transition
  /// (TextEditingController used after dispose -> red screen).
  final TextEditingController _pinController = TextEditingController();

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    ConsentStore.isTelemetryOptIn().then((v) {
      if (mounted) setState(() => _optIn = v);
    });
    ConsentStore.isCrashOptIn().then((v) {
      if (mounted) setState(() => _crashOptIn = v);
    });
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(() {
          _useClip = prefs.getBool('querypic_use_clip') ?? true;
        });
      }
    });
    AppIndex.ensure().then((app) {
      if (mounted) setState(() => _isPro = app.search.gate.isPro);
    });
    _refreshAccounts();
  }

  /// Reload profiles + role (called on open and after every account
  /// mutation). Tier display AND per-account settings (auto-transcribe)
  /// follow the ACTIVE profile — a Free profile must never show the
  /// admin's Pro toggles as on.
  Future<void> _refreshAccounts() async {
    final profiles = await AccountStore.profiles();
    final active = await AccountStore.active();
    final prefs = await SharedPreferences.getInstance();
    // Migrate a legacy global auto-transcribe flag onto this profile
    // once (pre-account installs), then read per-account only.
    final scoped = await AccountStore.scopedKey('auto_transcribe_stt');
    var auto = prefs.getBool(scoped) ?? false;
    if (!prefs.containsKey(scoped) &&
        (prefs.getBool('auto_transcribe_stt') ?? false)) {
      auto = true;
      await prefs.setBool(scoped, true);
    }
    AppIndex.ensure().then((app) async {
      final pro = await ProTierStore.isPro();
      app.search.gate.isPro = pro;
      final until = pro ? await ProTierStore.expiryMs() : null;
      if (!mounted) return;
      setState(() {
        _isPro = pro;
        _proUntil =
            until == null ? '' : 'Pro until ${_formatDate(until)}.';
      });
    }).catchError((_) {});
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _activeId = active?.id;
      _activeName = active?.name ?? '';
      _isAdmin = active?.isAdmin ?? false;
      _autoTranscribe = auto;
    });
  }

  Future<void> _runBenchmark() async {
    setState(() => _benchRunning = true);
    try {
      final result = await runPipelineBenchmark();
      if (!mounted) return;
      await _showBenchDialog(
        'Benchmark result',
        '$result\n\nSend these numbers back — they close Phase 2 task 5.',
      );
    } catch (e) {
      // Never red-screen: surfaced DB/device errors as a dialog instead.
      if (!mounted) return;
      await _showBenchDialog(
        'Benchmark failed',
        '$e\n\nSend this back so the failure can be fixed.',
      );
    } finally {
      if (mounted) setState(() => _benchRunning = false);
    }
  }

  Future<void> _runScaleTest() async {
    setState(() {
      _scaleRunning = true;
      _scaleProgress = 'Seeding 0 / 20,000… (a few minutes)';
    });
    try {
      final app = await AppIndex.ensure();
      await DemoSeed.seedScale(
        app.db,
        onProgress: (done, total) {
          if (mounted) {
            setState(() => _scaleProgress = 'Seeding $done / $total…');
          }
        },
      );
      if (mounted) {
        setState(() => _scaleProgress = 'Timing 6 queries…');
      }
      final result = await DemoSeed.runScaleQueries(app.search);
      if (!mounted) return;
      await _showBenchDialog('20k scale result', '$result');
    } catch (e) {
      if (!mounted) return;
      await _showBenchDialog('Scale test failed', '$e');
    } finally {
      if (mounted) {
        setState(() {
          _scaleRunning = false;
          _scaleProgress = null;
        });
      }
    }
  }

  /// Phase 4 walkthrough: seed videos + frames, then time video-relevant
  /// queries through the real search path (frameVectorScan + fusion).
  /// Also reports per-signal diagnostics (text/vector/frame sizes + where
  /// each demo video landed) so an empty video count is self-explaining.
  Future<void> _runVideoSeed() async {
    setState(() => _videoRunning = true);
    try {
      final app = await AppIndex.ensure();
      final frameCount = await DemoSeed.seedDemoVideos(app.db);
      final framesInDb = await app.db.countFrames();
      const queries = [
        'birthday',
        'ocean',
        'meeting',
        'hike',
        'sunset',
        'zxqvkw', // gibberish probe: must yield a clean empty state
      ];
      final videoUris = [
        for (final r in DemoSeed.videoRows) '${DemoSeed.videoScopePrefix}/${r.uri}',
      ];
      final lines = <String>[
        '4 videos indexed, $frameCount frames written, '
            '$framesInDb rows in frames table.',
        '',
      ];
      final timings = <int>[];
      for (final q in queries) {
        final traceLines = <String>[];
        final sw = Stopwatch()..start();
        final out = await app.search.search(q, trace: traceLines.add);
        sw.stop();
        timings.add(sw.elapsedMilliseconds);
        final byUri = out.where((r) => videoUris.contains(r.uri)).toList();
        final byFlag = out.where((r) => r.isVideo).toList();
        lines.add(
          '"$q": ${sw.elapsedMilliseconds}ms — ${out.length} hits, '
          '${byUri.length} videos by uri / ${byFlag.length} by flag',
        );
        lines.addAll(traceLines.map((l) => '   $l'));
        // Standalone re-run (plain List<int> input) for cross-comparison
        // against the in-_run trace above (Uint8List input).
        final qvec = await app.search.embedder.embed(q);
        final tRows = await app.db.tokenSearch('ocr', q, limit: 50);
        final vHits = await app.db.vectorScan(qvec, limit: 50);
        final fHits = await app.db.frameVectorScan(qvec, limit: 50);
        lines.add('   standalone: text=${tRows.length} '
            'vec=${vHits.length} frame=${fHits.length}');
        // Where did each demo video land?
        for (final uri in videoUris) {
          final row = await app.db.fileByUri(uri);
          final name = uri.split('/').last;
          if (row == null) {
            lines.add('   $name: MISSING from files');
            continue;
          }
          final id = row['id'] as int;
          final inText = tRows.any((r) => r['ref_id'] == id);
          final fh = fHits[id];
          lines.add(
            '   $name: type=${row['type']} text=$inText '
            'vec=${vHits.containsKey(id)} '
            'frame=${fh != null ? '${fh.sim.toStringAsFixed(2)}@${fh.t}s' : 'no'}',
          );
        }
        final rank = out.indexWhere((r) => videoUris.contains(r.uri));
        if (rank >= 0) {
          lines.add('   ▶ in results: #${rank + 1} '
              'score=${out[rank].score}% '
              '${out[rank].bestFrameSecs != null ? 'frame ${out[rank].bestFrameSecs}s' : ''}');
        }
        if (q == 'zxqvkw') {
          lines.add(
            out.isEmpty
                ? '   ▶ gibberish yields a clean empty state'
                : '   ▶ GIBBERISH LEAK: ${out.length} rows',
          );
        }
        lines.add('');
      }
      final sorted = timings.toList()..sort();
      final p95 = sorted[((sorted.length * 0.95).ceil() - 1)
          .clamp(0, sorted.length - 1)];
      lines.add('p95: ${p95}ms (budget <500ms)');
      lines.add(p95 < 500 ? 'Verdict: PASS' : 'Verdict: OVER BUDGET');
      if (!mounted) return;
      await _showBenchDialog('Phase 4 video seed', lines.join('\n'));
    } catch (e) {
      if (!mounted) return;
      await _showBenchDialog('Video seed failed', '$e');
    } finally {
      if (mounted) setState(() => _videoRunning = false);
    }
  }

  /// Phase 5 walkthrough (debug only): tier gate, fuzzy-temporal Free vs
  /// Pro, seek handoff construction, timed-frame probe. Runs both tiers
  /// through throwaway services so the persisted tier is untouched.
  Future<void> _runPhase5() async {
    setState(() => _phase5Running = true);
    try {
      final app = await AppIndex.ensure();
      final now = DateTime.now();
      final gate = app.search.gate;
      final lines = <String>[
        'tier: ${gate.isPro ? 'Pro' : 'Free'} '
        '(seek=${gate.canUse(ProFeature.seekToFrame)} '
        'fuzzy=${gate.canUse(ProFeature.fuzzyTemporal)} '
        'similar=${gate.canUse(ProFeature.visualSimilarity)})',
        '',
      ];
      final freeSvc = SearchService(
        db: app.db,
        embedder: app.search.embedder,
        gate: ProGate(),
      );
      final proSvc = SearchService(
        db: app.db,
        embedder: app.search.embedder,
        gate: ProGate(isPro: true),
      );
      var fuzzyOk = true;
      const probes = [
        'sunset from last summer',
        'recent birthday',
        'meeting this year',
      ];
      for (final q in probes) {
        final freeOut = await freeSvc.searchDetailed(q, now: now);
        final proOut = await proSvc.searchDetailed(q, now: now);
        final proBad =
            proOut.results.where((r) => !proOut.filter.admits(r.mtime)).length;
        lines.add('"$q"');
        lines.add(
          '  Free: ${freeOut.results.length} hits, '
          'preview=${freeOut.preview?.name ?? 'none'}',
        );
        lines.add(
          '  Pro: ${proOut.results.length} hits, '
          'filter=${proOut.filter.label ?? 'none'}, '
          'out-of-window=$proBad',
        );
        if (freeOut.preview != ProFeature.fuzzyTemporal ||
            !proOut.filter.isActive ||
            proBad > 0) {
          fuzzyOk = false;
        }
        lines.add('');
      }
      // Seek handoff probe (pure construction, no player launched).
      final hHttp = buildHandoff(
        'https://cdn.example.com/v/birthday.mp4',
        startSecs: 42,
        isPro: true,
      );
      final hContent = buildHandoff(
        'content://media/video/1',
        startSecs: 42,
        isPro: true,
      );
      final hFree = buildHandoff(
        'content://media/video/1',
        startSecs: 42,
        isPro: false,
      );
      lines.add('handoff http+Pro42s: ${hHttp.launch} '
          '(seek=${hHttp.seekApplied})');
      lines.add('handoff content+Pro42s: ${hContent.launch} '
          '(seek=${hContent.seekApplied} '
          'hint=${hContent.seekSecs != null ? formatSeek(hContent.seekSecs!) : '-'}'
          ')');
      lines.add('handoff content+Free: ${hFree.launch} '
          '(seek=${hFree.seekApplied})');
      final handoffOk = hHttp.seekApplied &&
          hHttp.launch.contains('t=42') &&
          !hContent.seekApplied &&
          !hFree.seekApplied;
      lines.add('');
      // Timed-frame probe: top-3 frames of the birthday video for its tag.
      var framesOk = false;
      final vid = await app.db.fileByUri(
        '${DemoSeed.videoScopePrefix}/birthday_party.mp4',
      );
      if (vid == null) {
        lines.add('frames probe: birthday video MISSING '
            '(run Seed demo videos first)');
      } else {
        final qvec = await app.search.embedder.embed('birthday');
        final top = await app.db.framesForFile(
          vid['id'] as int,
          qvec,
          limit: 3,
        );
        lines.add(
          'frames probe (birthday_party.mp4 x "birthday"): '
          '${top.isEmpty ? 'NONE' : top.map((e) => '${e.t}s@${e.sim.toStringAsFixed(2)}').join(' ')}',
        );
        framesOk = top.isNotEmpty &&
            top.first.t == 0.0 &&
            (top.first.sim - 1.0).abs() < 1e-9;
      }
      lines.add('');
      // Visual similarity probe: find items similar to a demo photo.
      var similarOk = false;
      final photo = await app.db.fileByUri(
        '${DemoSeed.scopePrefix}/sunset_pier.jpg',
      );
      if (photo == null) {
        lines.add('similar probe: sunset_pier MISSING '
            '(run Seed demo library first)');
      } else {
        final fid = photo['id'] as int;
        final freeSim = await freeSvc.findSimilarById(fid);
        final proSim = await proSvc.findSimilarById(fid);
        lines.add('similar probe:');
        lines.add('  Free: ${freeSim.results.length} hits, '
            'preview=${freeSim.preview?.name ?? 'none'}');
        lines.add('  Pro: ${proSim.results.length} hits');
        if (freeSim.results.isEmpty &&
            freeSim.preview == ProFeature.visualSimilarity &&
            proSim.results.isNotEmpty) {
          similarOk = true;
        }
      }
      lines.add('');
      // STT probe: transcribe demo videos (stub), phrase query must return
      // a timestamped hit (Phase 5 STT exit criterion).
      var sttOk = false;
      final stt = SttIndexer(db: app.db, engine: const StubSttEngine());
      var transcribed = 0;
      for (final r in DemoSeed.videoRows) {
        final uri = '${DemoSeed.videoScopePrefix}/${r.uri}';
        final row = await app.db.fileByUri(uri);
        if (row == null) continue;
        await stt.indexVideo(
          MediaEntry(
            uri: uri,
            isVideo: true,
            mtimeMillis: 0,
            sizeBytes: 0,
            durationSecs: r.durationSecs,
          ),
          row['id'] as int,
        );
        transcribed++;
      }
      final phrase = await proSvc.search('happy birthday', now: now);
      final bdayHits = phrase
          .where((x) => x.uri.endsWith('birthday_party.mp4'))
          .toList();
      lines.add('stt probe: transcribed $transcribed/'
          '${DemoSeed.videoRows.length} videos; '
          '"happy birthday" -> ${phrase.length} hits'
          '${bdayHits.isEmpty ? '' : ' (birthday video #${phrase.indexOf(bdayHits.first) + 1})'}');
      if (transcribed == 0) {
        lines.add('  (run Seed demo videos first)');
      } else if (bdayHits.isEmpty) {
        lines.add('  MISS: birthday video crowded out of results');
      } else {
        final segs = await app.db.transcriptsForFile(
          bdayHits.first.fileId,
        );
        lines.add('  segments: ${segs.length} '
            '(${segs.map((s) => '${s['t_start']}s').join(' ')})');
        sttOk = segs.length == 3;
      }
      final pass =
          fuzzyOk && handoffOk && framesOk && similarOk && sttOk;
      lines.add('');
      lines.add(pass ? 'Verdict: PASS' : 'Verdict: FAIL (see lines above)');
      if (!mounted) return;
      await _showBenchDialog('Phase 5 Pro checks', lines.join('\n'));
    } catch (e) {
      if (!mounted) return;
      await _showBenchDialog('Phase 5 checks failed', '$e');
    } finally {
      if (mounted) setState(() => _phase5Running = false);
    }
  }

  /// Media-read permission for the debug test-video path (Step 5).
  /// Tries the scoped videos permission first, falls back to storage.
  Future<bool> _ensureVideoPermission() async {
    if (await Permission.videos.isGranted) return true;
    if (await Permission.videos.request().isGranted) return true;
    if (await Permission.storage.isGranted) return true;
    return Permission.storage.request().isGranted;
  }

  /// Non-dismissible progress dialog (no Done button, taps outside
  /// ignored): the caller pops it when the work finishes or fails.
  void _showProgressDialog(String title, String body) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(body),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: Colors.grey,
        ),
      ),
    );
  }

  Future<void> _showBenchDialog(String title, String body) {    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: SelectableText(body),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  /// Account switcher: every profile listed with its role; switching TO
  /// an admin profile requires the admin PIN (typed inline). Tier display
  /// + live search gate refresh to the newly active profile.
  Future<void> _switchAccountDialog() async {
    final picked = await showDialog<AccountProfile>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Switch account'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final p in _profiles)
                ListTile(
                  selected: p.id == _activeId,
                  leading: Icon(
                    p.isAdmin
                        ? Icons.admin_panel_settings_outlined
                        : Icons.person_outline,
                  ),
                  title: Text(p.name),
                  subtitle: Text(p.isAdmin ? 'Administrator' : 'User'),
                  onTap: () => Navigator.of(ctx).pop(p),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (picked == null || picked.id == _activeId || !mounted) return;
    if (picked.isAdmin) {
      final okPin = await _askPin('Admin PIN required');
      if (okPin == null || !mounted) return;
      if (!await AccountStore.verifyPin(okPin)) {
        await _showBenchDialog(
          'Wrong PIN',
          'Staying on ${_activeName.isEmpty ? 'the current' : _activeName} account.',
        );
        return;
      }
      // Pass the VERIFIED pin: switchTo re-checks admin targets, and an
      // empty pin always fails (this silently swallowed correct PINs).
      await AccountStore.switchTo(picked.id, pin: okPin);
    } else {
      await AccountStore.switchTo(picked.id);
    }
    await _refreshAccounts();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Switched to ${picked.name} '
          '(${picked.isAdmin ? 'Administrator' : 'User'}).',
        ),
      ),
    );
  }

  /// Account removal. Private builds gate the entry to admins; public
  /// builds let anyone delete normal profiles (or themselves) — never
  /// the last profile, and the last-admin guard lives in AccountStore.
  Future<void> _removeAccountDialog() async {
    final deletable = [
      for (final p in _profiles)
        if (_profiles.length > 1 &&
            (kPublicBuild ? (!p.isAdmin || p.id == _activeId) : true))
          p,
    ];
    if (deletable.isEmpty) {
      await _showBenchDialog(
        'Cannot remove',
        'At least one profile must remain.',
      );
      return;
    }
    final target = await showDialog<AccountProfile>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove account'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final p in deletable)
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(p.name),
                  subtitle: Text(p.isAdmin ? 'Administrator' : 'User'),
                  onTap: () => Navigator.of(ctx).pop(p),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    final ok = await AccountStore.delete(target.id);
    if (!mounted) return;
    await _showBenchDialog(
      ok ? 'Removed' : 'Cannot remove',
      ok
          ? '${target.name} removed.'
          : 'The last administrator cannot be removed while other '
              'accounts exist.',
    );
    await _refreshAccounts();
  }

  /// Deliberate escape hatch (forgotten admin PIN included): wipes
  /// accounts, PIN, index, scopes, settings and Pro flags on this phone —
  /// the same as reinstalling, without re-downloading the app. Photos and
  /// videos themselves are never touched. Requires typing RESET.
  Future<void> _resetEverythingDialog() async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset everything?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This erases accounts, the admin PIN, the search index, '
              'indexed folders, settings and Pro unlocks on this phone. '
              'Your photos and videos stay exactly where they are.\n\n'
              'Type RESET to confirm.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: 'RESET',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () =>
                Navigator.of(ctx).pop(controller.text.trim() == 'RESET'),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    // Local controller: disposed only after the route fully settles
    // (disposing on pop crashes the exit transition — see _pinController).
    await Future.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    if (confirmed != true || !mounted) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      try {
        final docs = await getApplicationDocumentsDirectory();
        for (final name in ['index.db', 'index.db-journal', 'index.db-wal']) {
          try {
            final f = File('${docs.path}/$name');
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
      } catch (_) {}
      await AppIndex.resetForWipe();
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LandingScreen()),
      (_) => false,
    );
  }
  Future<String?> _askPin(String title) async {
    _pinController.clear();
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: _pinController,
          decoration: const InputDecoration(
            hintText: 'PIN',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.number,
          obscureText: true,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(_pinController.text),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    return pin;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionHeader('Library'),
          SwitchListTile(
            title: const Text('Local CLIP search'),
            subtitle: Text(
              _useClip
                  ? 'Real photo understanding (needs the on-device model)'
                  : 'Off — search matches labels, albums and dates only',
            ),
            value: _useClip,
            onChanged: (v) async {
              final prefs = await SharedPreferences.getInstance();
              // Re-arm the crash fuse on manual enable: two process deaths
              // disarm again automatically (see AppIndex).
              await prefs.setBool('querypic_use_clip', v);
              try {
                final docs = await getApplicationDocumentsDirectory();
                ClipFuse.writeSync(docs.path, 0);
              } catch (_) {}
              if (!mounted) return;
              setState(() => _useClip = v);
              await _showBenchDialog(
                v ? 'CLIP enabled' : 'CLIP disabled',
                v
                    ? 'Fully close and reopen the app, then check Model '
                        'status. If the app ever refuses to open twice in '
                        'a row, CLIP disarms itself — report back.'
                    : 'Takes effect on next launch (stub vectors return).',
              );
            },
          ),
          ListTile(
            title: const Text('Indexed folders'),
            subtitle: const Text('Add or revoke access at any time'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => const FolderPickerScreen(),),
            ),
          ),
          ListTile(
            title: const Text('Index size'),
            subtitle: const Text('Sandbox database + file counts'),
            trailing: const Icon(Icons.storage_outlined),
            onTap: () async {
              final app = await AppIndex.ensure();
              final bytes = await app.db.indexDbBytes();
              final real = await app.db.realFileCount();
              final frames = await app.db.countFrames();
              final mb = (bytes / (1024 * 1024)).toStringAsFixed(1);
              if (!mounted) return;
              await _showBenchDialog(
                'Index size',
                'Database: $mb MB\nReal files: $real\nFrame rows: $frames',
              );
            },
          ),
          ListTile(
            title: const Text('Rebuild index'),
            subtitle: const Text(
              'Clears all index rows and re-crawls granted folders',
            ),
            trailing: _rebuilding
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_outlined),
            onTap: _rebuilding
                ? null
                : () async {
                    setState(() => _rebuilding = true);
                    try {
                      final app = await AppIndex.ensure();
                      await app.db.clearIndex();
                      await app.worker.runOnce();
                      if (!mounted) return;
                      await _showBenchDialog(
                        'Index rebuilt',
                        'All rows cleared and re-crawled from granted '
                        'folders.',
                      );
                    } catch (e) {
                      if (!mounted) return;
                      await _showBenchDialog('Rebuild failed', '$e');
                    } finally {
                      if (mounted) setState(() => _rebuilding = false);
                    }
                  },
          ),
          _sectionHeader('Pro & subscription'),
          // Instant tier flip is a debug tool: normal users unlock Pro
          // through Paystack + license key (rows below). Never in public
          // builds (no admin abilities there at all).
          if (_isAdmin && !kPublicBuild)
            SwitchListTile(
              title: const Text('Pro tier (debug)'),
              subtitle: Text(
                _isPro
                    ? 'Pro: seek, smart dates, transcripts unlock'
                    : 'Free tier — Pro features show a paywall preview',
              ),
              value: _isPro,
              onChanged: (v) async {
                final app = await AppIndex.ensure();
                await app.search.gate.setTier(v);
                if (!mounted) return;
                setState(() => _isPro = v);
              },
            ),
          ListTile(
            title: const Text('Transcribe videos (Pro)'),
            subtitle: const Text(
              'Speech-to-text for videos missing transcripts',
            ),
            trailing: _transcribing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.mic_outlined),
            onTap: _transcribing
                ? null
                : () async {
                    final app = await AppIndex.ensure();
                    if (!context.mounted) return;
                    if (!app.search.gate.isPro) {
                      await showPaywallSheet(
                        context,
                        feature: ProFeature.stt,
                        gate: app.search.gate,
                      );
                      return;
                    }
                    if (!context.mounted) return;
                    setState(() => _transcribing = true);
                    // Captured before the async work (lint-safe across gaps).
                    final rootNavigator =
                        Navigator.of(context, rootNavigator: true);
                    // Counted progress dialog (done/total + bar) instead of
                    // an endless spinner: transcribing a library takes
                    // minutes per video on debug builds, and users deserve
                    // to see how far through ALL their videos it is.
                    var done = 0;
                    var total = 0;
                    var part = 0;
                    var dialogOpen = false;
                    void Function()? refresh;
                    // dialogOpen clears if the dialog closes any other way
                    // (system back button), so finally never double-pops.
                    unawaited(
                      showDialog<void>(
                        context: context,
                        barrierDismissible: false,
                        builder: (ctx) {
                          dialogOpen = true;
                          return StatefulBuilder(
                          builder: (ctx, setDialog) {
                            refresh = () => setDialog(() {});
                            final frac =
                                total == 0 ? 0.0 : done / total;
                            return AlertDialog(
                              title:
                                  const Text('Transcribing videos…'),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    total == 0
                                        ? 'Finding videos…'
                                        : 'Video ${done + 1 > total ? total : done + 1} '
                                            'of $total transcribed'
                                            '${part > 0 ? ' · part $part' : ''}',
                                  ),
                                  const SizedBox(height: 12),
                                  LinearProgressIndicator(
                                    value: total == 0 ? null : frac,
                                  ),
                                  const SizedBox(height: 8),
                                  const Text(
                                    'On-device Whisper — leave the app open.',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                            );
                          },
                        );
                      },
                    ).then((_) => dialogOpen = false),
                    );
                    var completed = 0;
                    var expected = 0;
                    try {
                      final q = TranscriptionQueue(
                        db: app.db,
                        engine: app.stt,
                      );
                      completed = await q.process(
                        isPro: true,
                        manual: true,
                        limit: 100,
                        onProgress: (d, t) {
                          done = d;
                          total = t;
                          part = 0;
                          refresh?.call();
                        },
                        onChunk: (c) {
                          part = c + 1;
                          refresh?.call();
                        },
                      );
                      expected = total;
                    } finally {
                      if (dialogOpen) {
                        rootNavigator.pop();
                      }
                      if (mounted) {
                        setState(() => _transcribing = false);
                      }
                    }
                    if (!mounted) return;
                    await _showBenchDialog(
                      'Transcription done',
                      expected == 0
                          ? 'No videos need transcripts.'
                          : '$completed of $expected video(s) transcribed '
                              'with speech.',
                    );
                  },
          ),
          SwitchListTile(
            title: const Text('Auto-transcribe on charge (Pro)'),
            subtitle: const Text(
              'Transcribe pending videos when charging or idle.',
            ),
            value: _autoTranscribe,
            onChanged: (v) async {
              // Enabling is a Pro action like everything else here: Free
              // users get the paywall, not a toggle that silently does
              // nothing (the queue itself is Pro-gated at run time).
              if (v) {
                final app = await AppIndex.ensure();
                if (!app.search.gate.isPro) {
                  if (!context.mounted) return;
                  await showPaywallSheet(
                    context,
                    feature: ProFeature.stt,
                    gate: app.search.gate,
                  );
                  return;
                }
              }
              final prefs = await SharedPreferences.getInstance();
              final scoped =
                  await AccountStore.scopedKey('auto_transcribe_stt');
              await prefs.setBool(scoped, v);
              if (!mounted) return;
              setState(() => _autoTranscribe = v);
            },
          ),
          ListTile(
            title: const Text('Enter license key'),
            subtitle: const Text('Beta Pro unlock (offline, 7-day grace)'),
            trailing: const Icon(Icons.key_outlined),
            onTap: () async {
              final controller = TextEditingController();
              final key = await showDialog<String>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Enter license key'),
                  content: TextField(
                    controller: controller,
                    decoration: const InputDecoration(
                      hintText: 'QP-PRO-XXXX-XXXX',
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, controller.text),
                      child: const Text('Activate'),
                    ),
                  ],
                ),
              );
              if (key == null || key.isEmpty || !mounted) return;
              // Single-use redemption: format first (typos fail fast),
              // then one backend call that burns the key (or dev bypass
              // when no backend is configured). Afterwards Pro is local
              // and fully offline.
              final outcome = await LicenseStore.redeem(key);
              if (!mounted) return;
              if (!outcome.ok) {
                await _showBenchDialog('Key rejected', outcome.message);
                return;
              }
              final app = await AppIndex.ensure();
              await LicenseStore.save(key);
              await ProTierStore.activate(outcome.validUntilMs);
              app.search.gate.isPro = await ProTierStore.isPro();
              await app.db.logAudit('license_activated', '');
              if (!mounted) return;
              setState(() => _isPro = app.search.gate.isPro);
              final until = await ProTierStore.expiryMs();
              if (!mounted) return;
              await _showBenchDialog(
                'Pro unlocked',
                until == null
                    ? outcome.message
                    : '${outcome.message}\nPro until ${_formatDate(until)}.',
              );
            },
          ),
          ListTile(
            title: const Text('Manage subscription'),
            subtitle: Text(
              BillingLinks.hasPortal
                  ? 'Customer portal (production checkout)'
                  : 'Plan status and support (beta checkout)',
            ),
            trailing: const Icon(Icons.payments_outlined),
            onTap: () async {
              final app = await AppIndex.ensure();
              if (!BillingLinks.isConfigured) {
                await _showBenchDialog(
                  'Not configured',
                  'Stripe links and store billing are connected at '
                  'release (production step). Beta uses license keys.',
                );
                return;
              }
              if (BillingLinks.hasPortal) {
                await launchUrl(
                  Uri.parse(BillingLinks.portalUrl),
                  mode: LaunchMode.externalApplication,
                );
                return;
              }
              await _showBenchDialog(
                'Manage subscription',
                'Pro tier: ${app.search.gate.isPro ? 'active' : 'not active'}.'
                '${_proUntil.isEmpty ? '' : '\n$_proUntil'}\n'
                '${BillingLinks.supportLine}',
              );
            },
          ),
          _sectionHeader('Accounts'),
          ListTile(
            leading: Icon(
              _isAdmin ? Icons.admin_panel_settings_outlined : Icons.person_outline,
            ),
            title: Text(
              _activeName.isEmpty ? 'Account' : _activeName,
            ),
            subtitle: Text(
              _isAdmin
                  ? 'Administrator — developer tools visible'
                  : 'Normal user — Pro via Paystack + license key',
            ),
            trailing: const Icon(Icons.switch_account_outlined),
            onTap: () => _switchAccountDialog(),
          ),
          // Any user can add profiles (always normal users in public
          // builds); deleting is admin-gated on private builds, self-or-
          // normal on public ones (never the last profile).
          ListTile(
            leading: const Icon(Icons.person_add_outlined),
            title: const Text('Add account'),
            subtitle: const Text(
              'Multiple profiles per phone; Pro unlocks per account',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final added = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => AccountSetupScreen(
                    adminEntry: _isAdmin && !kPublicBuild,
                  ),
                ),
              );
              if (added == true) _refreshAccounts();
            },
          ),
          if (_isAdmin || kPublicBuild)
            ListTile(
              leading: const Icon(
                Icons.person_remove_outlined,
                color: Colors.red,
              ),
              title: const Text('Remove account'),
              subtitle: const Text(
                kPublicBuild
                    ? 'Delete any profile except the last one'
                    : 'Admins only',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _removeAccountDialog(),
            ),
          // Always visible — including to locked-out users: this IS the
          // forgotten-PIN escape hatch (equivalent to reinstalling).
          ListTile(
            leading: const Icon(
              Icons.delete_forever_outlined,
              color: Colors.red,
            ),
            title: const Text('Reset everything'),
            subtitle: const Text(
              'Erase accounts, index and settings on this phone',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _resetEverythingDialog(),
          ),
          _sectionHeader('Privacy'),
          SwitchListTile(
            title: const Text('Anonymous crash reports'),
            subtitle: const Text('Stack traces + OS/model only. Default off.'),
            value: _optIn,
            onChanged: (v) async {
              await ConsentStore.setTelemetryOptIn(v);
              setState(() => _optIn = v);
            },
          ),
          SwitchListTile(
            title: const Text('Crash diagnostics'),
            subtitle: const Text(
              'Scrubbed stack traces only. Default off.',
            ),
            value: _crashOptIn,
            onChanged: (v) async {
              await ConsentStore.setCrashOptIn(v);
              setState(() => _crashOptIn = v);
            },
          ),
          ListTile(
            title: const Text('Privacy audit'),
            subtitle: const Text('Local-only event log, 0 bytes uploaded'),
            trailing: const Icon(Icons.verified_user_outlined),
            onTap: () async {
              final app = await AppIndex.ensure();
              final n = await app.db.auditCount();
              final recent = await app.db.recentAudit(limit: 10);
              if (!mounted) return;
              await _showBenchDialog(
                'Privacy audit',
                '$n events logged (local only).\n'
                '${recent.map((r) => '${r['event']}: ${r['detail']}').join('\n')}',
              );
            },
          ),
          if (_isAdmin && !kPublicBuild) ...[
            _sectionHeader('Developer tools'),
            _devTools(),
          ],
        ],
      ),
    );
  }

  /// Debug STT probe: real Whisper run on an adb-pushed file.
  /// Extracted verbatim from the former inline tile handler.
  Future<void> _transcribeTestVideo() async {
        final controller = TextEditingController(
          text: '/sdcard/Android/data/com.example.querypic/files/'
              'tts_test.wav',
        );
        final path = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Test video path'),
            content: TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: '/sdcard/Download/*.mp4',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, controller.text),
                child: const Text('Transcribe'),
              ),
            ],
          ),
        );
        if (path == null || path.isEmpty || !mounted) return;
        // Tolerate a missing leading slash (easy to eat while
        // editing the field) and file:// prefixes.
        var rawPath = path.trim();
        if (rawPath.startsWith('file://')) {
          rawPath = rawPath.substring('file://'.length);
        }
        if (!rawPath.startsWith('/')) rawPath = '/$rawPath';
        // Filesystem ground truth: authoritative storage root +
        // listing of the app dir, plus an automatic basename
        // fallback (push destinations and typed paths disagree more
        // often than expected).
        String? extDirPath;
        List<String> extListing = const [];
        try {
          final extRoot = await getExternalStorageDirectory();
          if (extRoot != null) {
            extDirPath =
                '${extRoot.path}/Android/data/com.example.querypic/files';
            extListing = Directory(extDirPath)
                .listSync()
                .map((e) => e.path.split('/').last)
                .take(20)
                .toList();
          }
        } catch (_) {}
        if (!await File(rawPath).exists()) {
          final base = rawPath.split('/').last;
          final alt = extDirPath == null
              ? null
              : '$extDirPath/$base';
          if (alt != null && await File(alt).exists()) {
            rawPath = alt;
          } else {
            await _showBenchDialog(
              'File not found',
              'Nothing at:\n$rawPath\n'
              'App dir: ${extDirPath ?? 'unknown'}\n'
              'App dir holds: '
              '${extListing.isEmpty ? '(empty/unreadable)' : extListing.join(', ')}',
            );
            return;
          }
        }
        if (!await _ensureVideoPermission()) {
          await _showBenchDialog(
            'Permission needed',
            'Grant video/file access, then retry.',
          );
          return;
        }
        final app = await AppIndex.ensure();
        if (!app.search.gate.isPro) {
          if (!mounted) return;
          await showPaywallSheet(
            context,
            feature: ProFeature.stt,
            gate: app.search.gate,
          );
          return;
        }
        final engine = TfliteSttEngine();
        if (!await engine.load()) {
          if (!mounted) return;
          await _showBenchDialog(
            'Engine unavailable',
            engine.lastError ??
                'assets missing — rebuild with '
                    'the whisper files in sandbox/models/',
          );
          return;
        }
        // Non-dismissible progress: the work runs while this is up.
        // (The old code awaited a Done button first, so nothing ran
        // until the user dismissed it — the label was a lie.)
        _showProgressDialog(
          'Transcribing…',
          'Running Whisper on-device. This can take several minutes '
          '(debug builds are slower than release). Leave the app open.',
        );
        try {
          final segs = await engine.transcribeStream(
            MediaEntry(
              uri: 'file://$rawPath',
              isVideo: true,
              mtimeMillis: DateTime.now().millisecondsSinceEpoch,
              sizeBytes: 0,
            ),
          );
          // Index the real transcript rows so speech is searchable.
          final row = await app.db.fileByUri('file://$rawPath');
          var fileId = row?['id'] as int?;
          if (row == null) {
            final nowMs =
                DateTime.now().millisecondsSinceEpoch;
            fileId = await app.db.insertIndexed(
              uri: 'file://$rawPath',
              isVideo: true,
              mtime: nowMs,
              size: 0,
              width: 0,
              height: 0,
              hash: 'file://$rawPath|$nowMs|0',
              vector: await app.search.embedder.embed(rawPath),
              modelVer: 'stub-v0',
              ocrText: '',
            );
          }
          await SttIndexer(db: app.db, engine: engine)
              .indexSegments(
            fileId!,
            segs,
          );
          if (!mounted) return;
          Navigator.of(context).pop();
          final rtf = engine.lastRealtimeFactor;
          final chunks = engine.lastChunkInfo.take(4).join('\n');
          if (segs.isEmpty && engine.lastChunkInfo.isEmpty) {
            await _showBenchDialog(
              'Transcription failed',
              'No audio frames decoded from $rawPath. Check the path, '
              'the file format, and storage permission.',
            );
            return;
          }
          await _showBenchDialog(
            'Transcription done',
            'Realtime factor: '
            '${rtf < 0 ? 'n/a' : '${rtf.toStringAsFixed(2)}x'}\n'
            'Segments: ${segs.length} '
            '(extractor v${engine.lastExtVersion})\n'
            '${chunks.isEmpty ? '' : '$chunks\n'}'
            '${segs.take(5).map((s) => '${formatSeek(s.tStart)} ${s.text}').join('\n')}',
          );
        } catch (e) {
          if (!mounted) return;
          Navigator.of(context).pop();
          final stack = engine.lastStack
              ?.split('\n')
              .take(8)
              .join('\n');
          await _showBenchDialog(
            'Transcription failed',
            '$e${stack == null ? '' : '\n$stack'}',
          );
        }
  }

  /// Everything below ships in beta but belongs to builders, not everyday
  /// users: benchmarks, seeders, model/STT probes and check dialogs.
  /// Collapsed by default so Settings reads like a normal app.
  Widget _devTools() {
    return ExpansionTile(
      leading: const Icon(Icons.build_outlined),
      title: const Text('Developer tools'),
      subtitle: const Text('Benchmarks, demo seeds, model checks'),
      children: [
        ListTile(
          title: const Text('Run pipeline benchmark'),
          subtitle: const Text(
            'Times 200 synthetic files on this device (debug only)',
          ),
          trailing: _benchRunning
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.speed_outlined),
          onTap: _benchRunning ? null : _runBenchmark,
        ),
        ListTile(
          title: const Text('Seed demo library'),
          subtitle: const Text(
            'Writes 12 sample rows via the real pipeline (debug only)',
          ),
          trailing: const Icon(Icons.science_outlined),
          onTap: () async {
            final app = await AppIndex.ensure();
            final n = await DemoSeed.seed(app.db);
            if (!mounted) return;
            await _showBenchDialog(
              'Demo library ready',
              '$n sample rows indexed.\n\nGo to Home and try "receipt", '
              '"sunset", "birthday" or "beach sunset from last week".',
            );
          },
        ),
        ListTile(
          title: const Text('Seed demo videos (Phase 4)'),
          subtitle: const Text(
            '4 videos + sampled frame rows, then runs video queries '
                '(debug only)',
          ),
          trailing: _videoRunning
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.videocam_outlined),
          onTap: _videoRunning ? null : _runVideoSeed,
        ),
        ListTile(
          title: const Text('Seed 20k scale test'),
          subtitle: Text(
            _scaleProgress ??
                'Writes 20,000 rows, then times 6 queries (debug only, '
                    'takes a few minutes)',
          ),
          trailing: _scaleRunning
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.query_stats_outlined),
          onTap: _scaleRunning ? null : _runScaleTest,
        ),
        ListTile(
          title: const Text('Clear synthetic rows'),
          subtitle: const Text(
            'Removes demo, video-demo + scale rows, keeps real index rows',
          ),
          trailing: const Icon(Icons.delete_sweep_outlined),
          onTap: () async {
            final app = await AppIndex.ensure();
            await DemoSeed.clearSynthetic(app.db);
            if (!mounted) return;
            await _showBenchDialog(
              'Cleared',
              'Demo and scale rows removed.',
            );
          },
        ),
        ListTile(
          title: const Text('Run Phase 5 Pro checks'),
          subtitle: const Text(
            'Tier gate, fuzzy dates Free vs Pro, seek handoff, timed '
            'frames (debug only)',
          ),
          trailing: _phase5Running
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.workspace_premium_outlined),
          onTap: _phase5Running ? null : _runPhase5,
        ),
        ListTile(
          title: const Text('Model status'),
          subtitle: const Text(
            'Whisper + CLIP asset load, shapes, vocab (Step 5 wiring)',
          ),
          trailing: const Icon(Icons.memory_outlined),
          onTap: () async {
            final app = await AppIndex.ensure();
            final stt = app.stt;
            final lines = <String>[
              'engine: ${stt.runtimeType} (${stt.modelVersion})',
            ];
            if (stt is TfliteSttEngine) {
              final ok = await stt.load();
              lines.add('loads: $ok');
              lines.add('threads: ${stt.numThreads}');
              lines.add('output shape: ${stt.outputShape}');
              lines.add('tensors: ${stt.tensorInfo}');
              lines.add('vocab entries: ${stt.vocabSize}');
              if (stt.lastError != null) {
                lines.add('error: ${stt.lastError}');
              }
            } else {
              lines.add('real engine absent: stub active '
                  '(assets ship inside the APK — rebuild to include)');
            }
            final clip = app.clip;
            if (clip == null) {
              final prefs = await SharedPreferences.getInstance();
              final useClip = prefs.getBool('querypic_use_clip') ?? true;
              var crashes = 0;
              try {
                final docs = await getApplicationDocumentsDirectory();
                crashes = await ClipFuse.read(docs.path);
              } catch (_) {}
              final present = await ClipJoint.findModelFile();
              if (present == null) {
                lines.add('clip: model file NOT on device '
                    '(enabled=$useClip fuse=$crashes/2 untouched; adb-push '
                    'clip_joint_s2.tflite to '
                    '${ClipJoint.triedPaths.isEmpty ? 'the sandbox models/ dir' : ClipJoint.triedPaths.join(', ')})');
              } else {
                lines.add('clip: load failed (enabled=$useClip fuse=$crashes/2; '
                    'file present at ${present.path})');
              }
            } else {
              lines.add('clip: joint loaded (${clip.tensorInfo})');
              lines.add(
                  'clip heads: text=out${clip.textOut} image=out${clip.imageOut} '
                  '(${clip.resolvedByProbe ? 'probe-resolved' : 'UNRESOLVED default'})');
              lines.add(
                  'clip last run: ${clip.lastMillis < 0 ? 'n/a' : '${clip.lastMillis.toStringAsFixed(0)}ms'}'
                  '${clip.lastError == null ? '' : ' err=${clip.lastError}'}');
            }
            if (!mounted) return;
            await _showBenchDialog('Model status', lines.join('\n'));
          },
        ),
        ListTile(
          title: const Text('CLIP load stage'),
          subtitle: const Text(
            'Segfault bisect: map-only vs full probe (restart to apply)',
          ),
          trailing: const Icon(Icons.science_outlined),
          onTap: () async {
            final prefs = await SharedPreferences.getInstance();
            final cur = prefs.getBool('querypic_clip_maponly') ?? false;
            await prefs.setBool('querypic_clip_maponly', !cur);
            try {
              final docs = await getApplicationDocumentsDirectory();
              ClipFuse.writeSync(docs.path, 0);
            } catch (_) {}
            if (!mounted) return;
            await _showBenchDialog(
              'CLIP stage: ${!cur ? 'map-only' : 'full probe'}',
              !cur
                  ? 'Model maps + tensor metadata only, zero inference. '
                      'Fully close + reopen: survives = killer is inference.'
                  : 'Full load with head-resolution probe. Fully close + '
                      'reopen to run it.',
            );
          },
        ),
        ListTile(
          title: const Text('Transcribe test video'),
          subtitle: const Text(
            'Real Whisper run on an adb-pushed file (Pro, debug only)',
          ),
          trailing: const Icon(Icons.record_voice_over_outlined),
          onTap: () => _transcribeTestVideo(),
        ),
        ListTile(
          title: const Text('Send test crash'),
          subtitle: const Text(
            'Step 7 check: scrubbed report via the crash pipeline '
            '(needs Crash diagnostics ON)',
          ),
          trailing: const Icon(Icons.bug_report_outlined),
          onTap: () async {
            if (!await ConsentStore.isCrashOptIn()) {
              await _showBenchDialog(
                'Crash diagnostics is OFF',
                'Turn ON "Crash diagnostics" first, then retry. '
                'Opted out means nothing is captured at all.',
              );
              return;
            }
            FlutterError.reportError(
              FlutterErrorDetails(
                exception: StateError(
                  'QueryPic test crash (Step 7 verification)',
                ),
                stack: StackTrace.current,
                library: 'settings',
                context: ErrorDescription('Step 7 DSN check'),
              ),
            );
            await _showBenchDialog(
              'Test crash sent',
              'Check Settings → Privacy audit for a '
              '"crash_queued_backend" row, then your GlitchTip '
              'project → Issues for the scrubbed report.',
            );
          },
        ),
      ],
    );
  }
}
