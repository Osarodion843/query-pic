/// Native-player handoff with Pro seek-to-tap (Phase 5, task 1; PRD §2).
///
/// Pure — unit-tested. The specified mechanism is the `?t=` parameter:
/// http(s) media opens right at the matched moment for Pro. Other schemes
/// (content/file) carry no seek channel through url_launcher, so the URI
/// opens unchanged and the caller surfaces [seekSecs] as a hint chip
/// ("matched moment 1:24 — player opens at start"). Free always opens at 0s.
({String launch, bool seekApplied, double? seekSecs}) buildHandoff(
  String rawUri, {
  double? startSecs,
  required bool isPro,
}) {
  if (!isPro || startSecs == null || startSecs <= 0) {
    return (launch: rawUri, seekApplied: false, seekSecs: null);
  }
  final uri = Uri.tryParse(rawUri);
  if (uri == null) {
    return (launch: rawUri, seekApplied: false, seekSecs: startSecs);
  }
  if (uri.scheme == 'http' || uri.scheme == 'https') {
    final t = startSecs % 1 == 0
        ? startSecs.toInt().toString()
        : startSecs.toStringAsFixed(1);
    final withT = uri.replace(
      queryParameters: {...uri.queryParameters, 't': t},
    );
    return (launch: withT.toString(), seekApplied: true, seekSecs: startSecs);
  }
  return (launch: rawUri, seekApplied: false, seekSecs: startSecs);
}

/// Clock-format helper for seek chips and play buttons.
String formatSeek(double secs) {
  final total = secs.round();
  final m = total ~/ 60;
  final s = total % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
