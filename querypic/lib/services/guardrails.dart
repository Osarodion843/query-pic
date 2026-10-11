import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Phase 6 guardrails (PRD §5/§6, Journey Phase 5):
/// battery / thermal / storage gates, offline-queue rules, RAM-pressure
/// model unload. Pure evaluation is unit-tested; platform readings arrive
/// over the `querypic/vitals` channel (MainActivity.kt / AppDelegate.swift)
/// with graceful unknown-fallbacks so unit tests and channel-less builds
/// never crash.

/// Thermal buckets, aligned on both platforms:
/// Android PowerManager 0..6 and iOS thermalState map to 0..3 here
/// (0 none, 1 light/fair, 2 moderate/serious, 3 critical+).
class DeviceVitals {
  final double? batteryPct;
  final bool? charging;
  final int? thermal;
  final int? freeDiskBytes;
  const DeviceVitals({
    this.batteryPct,
    this.charging,
    this.thermal,
    this.freeDiskBytes,
  });

  const DeviceVitals.unknown()
      : batteryPct = null,
        charging = null,
        thermal = null,
        freeDiskBytes = null;
}

/// Pause outcome for the index worker. Null from [Guardrails.evaluate]
/// means proceed; otherwise pause AFTER the current batch commits.
enum GuardDecision { pauseBattery, pauseThermal, pauseStorage }

class Guardrails {
  static const lowBatteryPct = 20.0;
  static const lowDiskBytes = 1024 * 1024 * 1024; // 1 GB

  /// Pure — unit-tested. Unknown readings never pause (fail-open would
  /// stall indexing forever on channel-less builds; the channel is the
  /// source of truth on device).
  static GuardDecision? evaluate({
    double? batteryPct,
    bool? charging,
    int? thermal,
    int? freeDiskBytes,
  }) {
    if (freeDiskBytes != null && freeDiskBytes < lowDiskBytes) {
      return GuardDecision.pauseStorage;
    }
    if (batteryPct != null &&
        batteryPct < lowBatteryPct &&
        charging != true) {
      return GuardDecision.pauseBattery;
    }
    if (thermal != null && thermal >= 2) {
      return GuardDecision.pauseThermal;
    }
    return null;
  }

  /// STT queue rule (Phase 5, task 2): on-demand (manual) always allowed
  /// for Pro; background transcription only when charging or idle.
  /// Unknown state waits rather than draining the battery.
  static bool shouldTranscribeNow({
    required bool isPro,
    bool? charging,
    bool? idle,
    bool manual = false,
  }) {
    if (!isPro) return false;
    if (manual) return true;
    return charging == true || idle == true;
  }
}

/// Platform vitals over `querypic/vitals`. Any failure (missing plugin on
/// host tests, channel errors) yields unknown — never throws.
class MethodChannelVitals {
  static const _channel = MethodChannel('querypic/vitals');

  static Future<DeviceVitals> read() async {
    try {
      final m =
          await _channel.invokeMapMethod<String, Object?>('getVitals');
      if (m == null) return const DeviceVitals.unknown();
      return DeviceVitals(
        batteryPct: (m['batteryPct'] as num?)?.toDouble(),
        charging: m['charging'] as bool?,
        thermal: (m['thermal'] as num?)?.toInt(),
        freeDiskBytes: (m['freeDiskBytes'] as num?)?.toInt(),
      );
    } on MissingPluginException {
      return const DeviceVitals.unknown();
    } on PlatformException {
      return const DeviceVitals.unknown();
    }
  }
}

/// Registry of loaded native models (CLIP/Whisper interpreters).
/// RAM-pressure events drop every handle here; models lazy-reload on next
/// use. Stubs register nothing, so the call is a safe no-op today.
class ModelCache {
  static final _loaded = <String, Object?>{};

  static void markLoaded(String name, [Object? handle]) =>
      _loaded[name] = handle;

  static void unloadAll() => _loaded.clear();

  static bool get isEmpty => _loaded.isEmpty;
  static int get count => _loaded.length;
}

/// Releases native model handles on OS memory pressure (Phase 6).
/// Registered in main() — fire-and-forget, never throws into the UI.
class MemoryPressureObserver with WidgetsBindingObserver {
  @override
  void didHaveMemoryPressure() {
    ModelCache.unloadAll();
  }
}
