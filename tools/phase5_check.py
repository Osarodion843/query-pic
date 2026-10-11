"""Phase 5 contract checks (host-runnable, static).

Verifies this turn's Phase 5 slice without a device:
  6. Feature gating: ProFeature enum, canUse matrix, subscribe stub,
     persisted tier, AppIndex wiring, paywall sheet, settings switch
  1. Timed frames: framesForFile query, ?t= handoff construction,
     Pro seek wiring in the preview sheet
  4. Fuzzy temporal: season/recent/year parsing with fuzzy flag,
     scaffolding strip with bare-season token kept, tier-resolved
     search (searchDetailed + preview), workspace preview chip

Remaining Phase 5 (STT pipeline + transcript UI, visual similarity)
lands next; device steps run on hardware.

Usage: python tools/phase5_check.py
Exit 0 on PASS, 1 on FAIL.
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "querypic", "lib")
TESTS = os.path.join(ROOT, "querypic", "test")


def read_dart(*parts: str) -> str:
    with open(os.path.join(LIB, *parts), encoding="utf-8") as f:
        return f.read()


def main() -> int:
    failures: list[str] = []

    def check(name: str, cond: bool, hint: str = ""):
        print(f"[{'PASS' if cond else 'FAIL'}] {name}"
              + (f" — {hint}" if hint and not cond else ""))
        if not cond:
            failures.append(name)

    for rel in ("services/pro_gate.dart", "services/handoff.dart",
                "screens/paywall_sheet.dart", "services/query_engine.dart",
                "services/search_service.dart", "services/app_index.dart",
                "screens/settings_screen.dart",
                "screens/workspace_screen.dart"):
        check(f"exists {rel}", os.path.isfile(os.path.join(LIB, rel)))

    # --- Task 6: feature gating ----------------------------------------
    gate = read_dart("services", "pro_gate.dart")
    for feature in ("timedFrames", "seekToFrame", "stt", "transcript",
                    "fuzzyTemporal", "visualSimilarity"):
        check(f"gate: ProFeature.{feature}", feature in gate)
    check("gate: canUse matrix", "canUse(ProFeature" in gate)
    check("gate: subscribe stub", "subscribe()" in gate)
    check("gate: tier persisted",
          "ProTierStore" in gate and "querypic_is_pro" in gate)
    check("gate: AppIndex wires gate into search",
          "ProGate()" in read_dart("services", "app_index.dart") and
          "gate: gate" in read_dart("services", "app_index.dart"))
    check("gate: settings Pro switch",
          "Pro tier (debug)" in
          read_dart("screens", "settings_screen.dart"))
    check("gate: paywall sheet with preview + subscribe",
          "showPaywallSheet" in
          read_dart("screens", "paywall_sheet.dart") and
          "Subscribe" in read_dart("screens", "paywall_sheet.dart"))

    # --- Task 4: fuzzy temporal ----------------------------------------
    engine = read_dart("services", "query_engine.dart")
    for kw in ("last summer", "this winter", "recent", "last year",
               "this year", "fall"):
        check(f"fuzzy: parses '{kw}'", kw in engine)
    check("fuzzy: DateFilter carries fuzzy flag", "fuzzy = false" in engine)
    check("fuzzy: scaffolding stripped",
          "stripDateKeywords" in engine and "'last summer'" in engine)
    check("fuzzy: bare season kept as token (re-rank)",
          "bare\n/// season" in engine or "bare season" in engine.lower())
    check("fuzzy: tier resolution is pure",
          "resolveFilter" in gate and "preview" in gate)
    svc = read_dart("services", "search_service.dart")
    check("search: tier-aware searchDetailed", "searchDetailed" in svc)
    check("search: preview plumbing", "preview:" in svc)
    check("search: gate field on service", "final ProGate gate" in svc)
    ws = read_dart("screens", "workspace_screen.dart")
    check("ui: Free fuzzy preview chip", "Pro preview" in ws)
    check("ui: chip opens paywall", "showPaywallSheet" in ws)

    # --- Task 5: visual similarity -------------------------------------
    check("db: vectorForFile query",
          "vectorForFile" in read_dart("services", "index_database.dart"))
    check("search: findSimilar plumbing", "findSimilar(" in svc)
    check("search: findSimilarById plumbing", "findSimilarById(" in svc)
    check("fuzzy: similar resolution is pure",
          "resolveSimilar" in gate)
    check("ui: preview sheet find-similar button",
          "Find similar" in ws and "onFindSimilar" in ws)
    sim = read_dart("screens", "similar_screen.dart")
    check("ui: similar results screen grid",
          "GridView.builder" in sim and "SimilarScreen" in sim)

    # --- Task 1: timed frames + seek -----------------------------------
    hand = read_dart("services", "handoff.dart")
    check("handoff: ?t= construction", "'t': t" in hand or '"t"' in hand)
    check("handoff: scheme-aware (http seeks, content hints)",
          "https" in hand and "seekApplied" in hand)
    check("handoff: clock-format helper", "formatSeek" in hand)
    check("db: framesForFile top-N query",
          "framesForFile" in read_dart("services", "index_database.dart"))
    check("ui: preview play label seeks on Pro",
          "Play from" in ws and "bestFrameSecs" in ws)
    check("ui: Free seek upsell to paywall",
          "ProFeature.seekToFrame" in ws)
    check("settings: Phase 5 checks entry point",
          "Run Phase 5 Pro checks" in
          read_dart("screens", "settings_screen.dart"))

    # --- Tasks 2+3: STT pipeline + transcript UI -----------------------
    stt = read_dart("services", "stt_indexer.dart")
    check("stt: SttEngine interface + stub",
          "abstract class SttEngine" in stt and "StubSttEngine" in stt)
    check("stt: per-video vocabulary with timestamps",
          "vocabFor" in stt and "tStart" in stt)
    check("stt: transcripts indexed + tokenized",
          "SttIndexer" in stt and "'transcript'" in stt)
    check("search: transcript tokens merged into hits",
          "'transcript'" in svc)
    check("db: transcriptsForFile query",
          "transcriptsForFile" in
          read_dart("services", "index_database.dart"))
    check("ui: transcript segments tappable with seek",
          "_TranscriptView" in ws and "onSeek" in ws)
    check("settings: STT probe in Phase 5 checks",
          "stt probe" in read_dart("screens", "settings_screen.dart"))
    vt = open(os.path.join(TESTS, "video_test.dart"),
              encoding="utf-8").read()
    check("test: STT stub vocabulary", "StubSttEngine" in vt)

    # --- Step 5: real Whisper wiring ---------------------------------
    check("stt: TfliteSttEngine with asset fallback",
          "TfliteSttEngine" in read_dart("services", "tflite_stt.dart") and
          "fromAsset" in read_dart("services", "tflite_stt.dart"))
    check("stt: Dart log-mel frontend",
          "WhisperMel" in read_dart("services", "mel.dart") and
          "chunkWindow" in read_dart("services", "mel.dart"))
    check("stt: vocab loader + timestamp decoder",
          "WhisperVocab" in read_dart("services", "whisper_vocab.dart") and
          "decodeWhisperSegments" in
          read_dart("services", "whisper_decoder.dart"))
    check("stt: audio extraction channel",
          "querypic/audio" in read_dart("services", "audio_extractor.dart"))
    models = os.path.join(ROOT, "querypic", "sandbox", "models")
    check("models: timestamp whisper variant on disk",
          os.path.isfile(os.path.join(
              models, "whisper-with-timestamp-tiny-en.tflite")))
    check("models: plain whisper-tiny-en on disk",
          os.path.isfile(os.path.join(models, "whisper-tiny-en.tflite")))
    check("models: transcribe-translate variant on disk",
          os.path.isfile(os.path.join(
              models, "whisper-tiny-transcribe-translate.tflite")))
    check("models: engine defaults to the verified file",
          "this.modelAsset = "
          "'sandbox/models/whisper-tiny-transcribe-translate.tflite'" in
          read_dart("services", "tflite_stt.dart"))
    check("models: whisper vocab on disk",
          os.path.isfile(os.path.join(models, "whisper_vocab.json")))
    with open(os.path.join(ROOT, "querypic", "android", "app", "src",
                           "main", "kotlin", "com", "example", "querypic",
                           "MainActivity.kt"),
              encoding="utf-8") as f:
        kt = f.read()
    check("stt: output buffers honored at [offset, offset+size)",
          "info.offset" in kt)
    check("stt: PCM decoded in Dart with fallback (untrusted flag)",
          "decodeMono" in read_dart("services", "resample.dart"))
    check("stt: extractor returns raw bytes + metadata",
          "extractPcmRaw" in kt)
    check("stt: Dart PCM decode with fallback",
          "decodeMono" in read_dart("services", "resample.dart"))
    check("stt: bandlimited sinc resampler",
          "resample16k" in read_dart("services", "resample.dart"))
    check("stt: extractor build fingerprinted",
          '"ext"' in kt)
    check("stt: PCM sanitized before mel",
          "sanitizePcm" in read_dart("services", "tflite_stt.dart"))
    check("stt: AppIndex prefers real engine, stub fallback",
          "TfliteSttEngine()" in read_dart("services", "app_index.dart"))
    check("stt: settings model status + test-video rows",
          "Model status" in read_dart("screens", "settings_screen.dart") and
          "Transcribe test video" in
          read_dart("screens", "settings_screen.dart"))
    check("stt: model input laid out [1][80][3000]",
          "window[t][m]" in read_dart("services", "tflite_stt.dart"))
    check("stt: invoke errors carry tensor info + stack",
          "tensorInfo" in read_dart("services", "tflite_stt.dart") and
          "lastStack" in read_dart("services", "tflite_stt.dart"))
    check("stt: hallucination filter (loops + script gate)",
          "filterHallucinations" in
          read_dart("services", "whisper_decoder.dart"))
    with open(os.path.join(ROOT, "querypic", "android", "app", "src",
                           "main", "AndroidManifest.xml"),
              encoding="utf-8") as f:
        manifest = f.read()
    check("stt: media permission for debug path",
          "READ_MEDIA_VIDEO" in manifest)
    sq = open(os.path.join(TESTS, "stt_test.dart"),
              encoding="utf-8").read()
    for name in ("feature floor", "timestamp pairs delimit",
                 "localPathFor", "missing assets fail closed",
                 "leading eot skipped", "repetition loop",
                 "non-Latin-majority"):
        check(f"test: covers '{name}'", name in sq)
    rq = open(os.path.join(TESTS, "resample_test.dart"),
              encoding="utf-8").read()
    for name in ("decodes int16 LE mono", "falls back across a lying flag",
                 "rejects aliases", "unity DC gain",
                 "parses PCM16 mono wav"):
        check(f"test: covers '{name}'", name in rq)

    # --- Tests ----------------------------------------------------------
    st = open(os.path.join(TESTS, "search_test.dart"),
              encoding="utf-8").read()
    for name in ("fuzzy temporal parsing", "resolveFilter + ProGate",
                 "buildHandoff", "last summer", "Winter 2024",
                 "gate matrix", "?t="):
        check(f"test: covers '{name}'", name in st)

    print()
    if failures:
        print(f"FAIL: {len(failures)} failures")
        return 1
    print("PASS: 0 failures")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
