import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sentry/sentry.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/home_search_screen.dart';
import 'screens/landing_screen.dart';
import 'screens/welcome_screen.dart';
import 'services/account_store.dart';
import 'services/analytics.dart';
import 'services/app_index.dart';
import 'services/backend_keys.dart';
import 'services/consent_store.dart';
import 'services/guardrails.dart';
import 'services/scope_store.dart';
import 'services/scrub.dart';
import 'services/stt_indexer.dart';
import 'theme.dart';

/// QueryPic MVP shell (Phase 1).
/// First run: Welcome -> Consent (default off) -> Folder scope -> Home.
/// Returning users land directly on Home. Settings allows rescope + revoke.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Phase 6: drop native model handles on OS memory pressure.
  WidgetsBinding.instance.addObserver(MemoryPressureObserver());
  // Phase 7/8: count-only analytics stay on device (audit log) until a
  // backend key is configured (Step 7: paste into BackendKeys + rebuild).
  Analytics.recorder =
      (event, detail) => AppIndex.ensure().then((app) async {
            await app.db.logAudit(event, detail);
          });
  // Step 7: no-op while BackendKeys.aptabaseAppKey is empty (beta state).
  unawaited(Analytics.initBackend());
  // Phase 8: scrubbed crash reports to the local audit log (zero egress).
  // Step 7 GlitchTip: when a DSN is pasted, ALSO forward the already-scrubbed
  // payload. The opt-in gate below stays the single switch: opted out means
  // nothing is captured at all, audit log included.
  FlutterError.onError = (details) {
    ConsentStore.isCrashOptIn().then((optIn) {
      if (!optIn) return;
      AppIndex.ensure().then((app) {
        AuditLogCrashReporter(app.db.logAudit)
            .report(details.exception, details.stack ?? StackTrace.empty);
        if (BackendKeys.glitchTipDsn.isNotEmpty) {
          GlitchTipCrashReporter(app.db.logAudit, BackendKeys.glitchTipDsn)
              .report(details.exception, details.stack ?? StackTrace.empty);
          Sentry.captureException(
            GlitchTipCrashReporter.safeMessage(details.exception),
            stackTrace: details.stack,
          );
        }
      });
    });
  };
  if (BackendKeys.glitchTipDsn.isEmpty) {
    runApp(const QueryPicApp());
    return;
  }
  // Pure-Dart Sentry client (no native plugin, no Kotlin): active only
  // with a pasted DSN. Belt-and-braces scrub: allowlist is stack/os/model
  // — user identity dropped, exception values re-scrubbed before anything
  // leaves the device.
  await Sentry.init(
    (options) {
      options.dsn = BackendKeys.glitchTipDsn;
      options.tracesSampleRate = 0;
      options.beforeSend = (event, hint) {
        final exceptions = event.exceptions?.map((e) {
          return e.copyWith(value: e.value == null ? null : Scrub.text(e.value!));
        }).toList();
        return event.copyWith(
          user: null,
          exceptions: exceptions,
        );
      };
    },
  );
  runApp(const QueryPicApp());
}

class QueryPicApp extends StatelessWidget {
  const QueryPicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QueryPic',
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      home: const _OnboardingGate(),
    );
  }
}

class _OnboardingGate extends StatefulWidget {
  const _OnboardingGate();

  @override
  State<_OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends State<_OnboardingGate> {
  bool? _done;
  bool? _hasAccounts;

  @override
  void initState() {
    super.initState();
    // Open the sandbox index early (fire and forget): search and seeding
    // pick it up via AppIndex.current once ready.
    AppIndex.ensure().then((app) async {
      // Kick the indexer when albums are scoped so the library is fresh
      // without a manual visit to Settings. Guardrailed + re-entry safe.
      try {
        final scopes = await ScopeStore.getScopedUris();
        if (scopes.isNotEmpty) unawaited(app.worker.runOnce());
      } catch (_) {}
      // Phase 6: auto-transcribe pending videos when the user opted in
      // and the device is charging/idle. Unknown vitals wait (no drain).
      // The flag is per active account (a Free profile never inherits it).
      final prefs = await SharedPreferences.getInstance();
      final scoped = await AccountStore.scopedKey('auto_transcribe_stt');
      var auto = prefs.getBool(scoped) ?? false;
      if (!prefs.containsKey(scoped)) {
        auto = prefs.getBool('auto_transcribe_stt') ?? false;
      }
      if (auto) {
        final vitals = await MethodChannelVitals.read();
        await TranscriptionQueue(db: app.db, engine: const StubSttEngine())
            .process(
          isPro: app.search.gate.isPro,
          charging: vitals.charging,
          idle: false,
        );
      }
    });
    ConsentStore.isOnboardingDone().then((v) {
      if (mounted) setState(() => _done = v);
    });
    AccountStore.hasAccounts.then((v) {
      if (mounted) setState(() => _hasAccounts = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_done == null || _hasAccounts == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    // Accounts gate everything: no profile -> marketing landing, whose
    // only exit is creating one. Consent gate unchanged after that.
    if (!_hasAccounts!) return const LandingScreen();
    if (!_done!) return const WelcomeScreen();
    return FutureBuilder(
      future: AppIndex.ensure(),
      builder: (context, snap) {
        final worker = snap.data?.worker;
        if (worker == null) return const HomeSearchScreen();
        return HomeSearchScreen.wired(worker);
      },
    );
  }
}