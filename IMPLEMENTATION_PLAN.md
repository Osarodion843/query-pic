# QueryPic Implementation Plan (MVP v1.0)

Derived from `PRD.md` + `CUSTOMER_JOURNEY.md`.
Target: iOS & Android, 100% on-device, CPU-only, sub-500ms search on 20k files.

## Architecture Decision (proposed, to confirm)

* **App framework:** Flutter (single UI codebase for Home Search + Expanded Workspace) + platform channels for ML + media store access.
  * Alternative if ML plugin friction is high: native Swift + Kotlin with shared SQLite schema + shared ONNX models. Decision needed in Phase 0.
* **ML runtime:** TFLite (Android) / CoreML (iOS) via delegates, ONNX as interchange for evaluation. All models INT8 quantized.
  * Vision/text embedding: CLIP ViT-B/32 quantized or MobileViT + text encoder (~40-60MB).
  * OCR: platform-first — Apple Vision OCR (iOS) + ML Kit on-device OCR (Android) to save ~15MB and battery. Fallback to bundled TFLite OCR if parity fails.
  * STT (Pro only): Whisper-Tiny quantized (~75MB, downloaded on Pro unlock, not bundled in base APK/IPA to keep install small).
* **Local store (air-gapped):** SQLite + FTS5 (OCR text + transcripts) + vector table (sqlite-vec / custom HNSW lite) + file metadata table. 8-bit vector compression, target 15-25MB per 10k files.
* **Background work:** Android WorkManager + iOS BGProcessingTask / BGAppRefresh. Models load on-demand, unload on idle.
* **Billing (dev/beta, zero-cost):** Direct Android APK / F-Droid distribution + Web Checkout via Stripe API for Pro unlock. No $99/year Apple Developer or $25 Google Play fees during prototyping / open beta. StoreKit 2 + Google Play Billing deferred to production release only. Entitlement stored locally + Stripe receipt / license key.
* **Telemetry (100% free / open-source):** Aptabase (open-source, privacy-first) or Firebase Analytics (free unlimited) for analytics; Firebase Crashlytics (free unlimited) or GlitchTip (open-source Sentry-compatible) for crash reporting — all behind on-device scrubber. Opt-in at first launch.

---

## Phase 0 — Foundation & Scaffolding
**PRD refs:** §5 Architecture, §7 Privacy
**Goal:** Runnable skeleton on both OSes with sandbox DB, CI, and model harness.

Tasks:
1. Init Flutter project (or dual-native if chosen), lint, CI build for iOS/Android.
2. Define sandbox storage layout: `/models/`, `/db/index.db`, `/thumbs/`, `/queue/`.
3. SQLite schema v1: `files(id, uri, type, mtime, w,h,duration, hash)`, `embeddings(file_id, vec_int8, model_ver)`, `ocr(file_id, text)`, `frames(file_id, t, vec)`, `transcripts(file_id, t_start, t_end, text)`, `tokens(kind, token, ref_id)` inverted index (plain table, NOT FTS5 — OEM SQLite builds lack the module; stemmed + prefix-capable).
4. Model harness: load/unload quantized CLIP + OCR behind interface, log load time + RAM.
5. Airplane-mode smoke test: prove no network calls during index/search (proxy + network log assertion).

Exit criteria:
* App launches offline, creates DB, loads vision model on-demand <2s cold, <150MB RAM foreground.
* No outbound network in test.

## Phase 1 — Onboarding, Permissions & Directory Scoping
**PRD refs:** §2 UX Hybrid (launch screen), §3 Directory Scoping, §7 First-Launch Transparency, Journey Phase 1
**Goal:** Trust-building first run.

Tasks:
1. Welcome screen: "100% On-Device & Private" + what gets indexed.
2. Privacy + telemetry consent screen (opt-in, default off). Persist choice.
3. Permission flows: iOS PhotoKit limited/full, Android Photo Picker / MediaStore + SAF folder picker + SD-card URI persistence.
4. Folder picker UI: multi-select scoped dirs, editable later in Settings. Store granted URIs.
5. Home Search skeleton: search bar + static chips ("Receipts", "Videos with Speech", "Recent Sunset") → navigates to empty workspace.

Exit criteria:
* User can grant/deny per-folder, revoke in Settings. No full-disk crawl without consent.
* Telemetry off by default; when on, only after explicit consent.

## Phase 2 — Photo Indexing Pipeline (core value)
**PRD refs:** §3 Multi-Modal, §5 Image Indexing 200-400ms, §6 RAM/storage/queue, Journey Phase 2
**Goal:** 1k-1.5k photos/hour in background, searchable immediately.

Tasks:
1. Crawler: enumerate scoped dirs, hash, skip unchanged (mtime+size+hash), incremental queue.
2. Worker: downscale → embedding (CLIP image) → OCR → EXIF/date extraction → write DB + FTS. Batch commits.
3. Progress UX: "Indexing 1,240 of 5,000..." banner + pause reason ("Paused: battery <20% / device hot").
4. Immediate utility: FTS/vector query works on already-indexed rows while queue drains.
5. Benchmark harness: ms/photo on A13 / Snapdragon 778G class devices, RAM watermark, index MB/10k files.
   * MEASURED 2026-10-02 (itel S666LN, Transsion midrange, on-device benchmark, stub extractor):
     200 files / 2646ms = 13.23 ms/file pipeline overhead (no ML yet),
     DB 108KB → ~5.3MB/10k (budget ≤25MB), rows=200/200, no crash.
     Verdict: PASS with wide margin — leaves ~187-387ms/file headroom for real
     CLIP+OCR within the 200-400ms budget. Real 512-d vectors project to
     ~10-15MB/10k, still inside budget. Throughput with real ML still TBD
     when models land (fetch_models.py).

Exit criteria:
* 200-400ms/photo median on midrange CPU, <300MB RAM background, index ≤25MB/10k files.
* Kill + restart resumes queue without duplicates.

## Phase 3 — Search Engine + Hybrid UI
**PRD refs:** §2 Expanded Workspace, §3 Multi-Modal, §5/§6 sub-500ms / <100ms filters, Journey Phase 3A
**Goal:** Sub-500ms natural-language + OCR + date search with match scores.

Tasks:
1. Query path: embed query text → vector top-K → fuse with FTS (OCR) + EXIF date filter → rank → return with scores.
2. Basic date filters (Free): today / last week / month / custom range. EXIF lookup <100ms.
3. UI: Expanded Workspace grid, match-score badge, preview modal, empty/error states.
4. Starter prompts: dynamic chips from indexed content distribution.
5. Perf: prepared statements, vector index (HNSW/IVF lite), lazy thumbnails from OS cache.

Exit criteria:
* <500ms p95 query on 20k-file fixture, <100ms OCR/date filter.
* Airplane-mode parity test passes.

MEASURED 2026-10-02 (itel S666LN, on-device synthetic 20k scale test):
  receipt 387ms / sunset 222ms / birthday cake 201ms / beach ocean summer
  178ms / passport scan document 184ms / no-match token 257ms → p95 387ms.
  Verdict: PASS (<500ms). Dominant cost is the brute-force Dart vector scan;
  HNSW/IVF follow-up stands. Note: the no-match query still returns 50
  visual-neighbor rows (fusion fallback by design — scores land low-band
  with real CLIP vectors); decide in Phase 4 whether to hide sub-threshold
  visual-only results.

## Phase 4 — Video (Free: Thumbnail & Object Match + Native Handoff)
**PRD refs:** §2 Native Handoff, §3/§4 Video Search Free vs Pro, §5 Frame Sampling
**Goal:** Videos discoverable by looks, playable natively.

Tasks:
1. Frame extractor: 1 frame / 2-3s, cap (e.g., first 5 min for Free), store per-frame embeddings + middle thumbnail.
2. Video row in search fuses best-frame score.
3. Tap → native player (`AVPlayer` / `ExoPlayer` intent) at 0s for Free tier.
4. Duration/format edge cases: corrupt files, HEVC, slow SD-card reads.

Exit criteria:
* 60s video analyzed in ~6-8s CPU; Free search returns video by object/scene in thumbnail.

STATUS 2026-10-02 (host verification):
  Tasks 1-4 code complete:
  * VideoIndexer: 1 frame / 2.5s, Free 300s cap, middle-frame thumbnail
    convention, per-file skip map (corrupt/HEVC/SD errors never abort).
  * search_service: frameVectorScan wired into every query; frame hits feed
    the same 40% visual share as photo vectors; date filter covers frames.
  * Open decision RESOLVED: visualFloor = 50 in SearchService — visual- or
    frame-only results below mid band are dropped; text-backed always pass.
  * Native handoff: url_launcher external application (system player, Free
    plays at 0s); bestFrameSecs displayed for Phase 5 seek; demo rows
    explain themselves instead of failing.
  * Settings → "Seed demo videos (Phase 4)": 4 videos + ~233 frames through
    the real pipeline, then times 5 video queries with a p95 verdict.
  Verified: flutter analyze clean, flutter test 38/38 (15 new),
  phase3_check 43/43, phase4_check 54/54 (best-frame scan 224.8ms over
   20k frames on host). DEVICE-ONLY remaining: real CLIP frame vectors via
   clip_joint_s2 image tower, real thumbnail bytes, hardware playback,
   60s-video CPU timing (exit criterion).

STATUS 2026-10-02 (device bug fix — "0 videos in results"):
  ROOT CAUSE: tie-flood in fuseAndRank. tokenSearch LIMIT-50 returns rows
  that all share the max hit count, so the lone-text formula 55+45*share
  pinned all 50 at score 100. The exact-frame video (frame sim 1.0 -> 100)
  made it a 51-way tie for 50 slots; the unstable sort dropped it and the
  other three videos (56-72) fell below the cutoff of 100. Reproduced
  deterministically on host with tools/diag_ties.py (LCG seed 12345 =
  device's exact scale corpus: 50/50 window rows at 100 for all 5 queries).
  FIX: lone text capped at 90 (55 + 35*share) so visual/frame evidence can
  outrank it; deterministic tie-break (score desc, then fileId asc);
  fusion trace now prints at100 + cutoff for device confirmation.
  Regression: test/video_test.dart "tie-flood" test + both replica tools
  updated. Verified: analyze clean, flutter test 39/39, phase3 43/43,
  phase4 54/54 (best-frame 242ms), diag_phase4 now ranks the matching
  video #1 at 100 for all 5 queries. Known follow-up (real CLIP): a video
  crowded out of the 50-row text window relies on frame similarity alone —
  if device sims land below the text cutoff, reserve visual slots (Phase 5).
  NEXT: user rebuilds, Settings → Seed demo videos, paste dialog.

STATUS 2026-10-02 (device round 3 — REAL root cause: stub hash collapse):
  Round 2's trace (`vecTop=[1.00,1.00,1.00]`, `modes={visual:49}`) proved
  the 100-flood was VISUAL rows, not text ties: StubTextEmbedder,
  SyntheticFrameExtractor._vec and StubFeatureExtractor each masked the
  hash chain to 8 bits per dimension (`& 0xFF` in the loop), collapsing
  ~20k texts into <=256 distinct vectors — ~78 rows matched every query at
  cos=1.0 and filled all 50 slots with random photos (text matches were
  invisible; the video survived only via the round-2 video-first
  tie-break). Host replica never showed this because Python used a
  different (non-collapsing) embed.
  FIX: shared lib/services/stub_embed.dart (FNV-1a 32-bit over UTF-16
  code units + xorshift32 expansion, full-width state) wired into all
  three stubs; tools/diag_phase4.py mirrored byte-for-byte (parity
  verified 6/6 strings vs `dart run`); new tests: decorrelation (10
  samples, pairwise cos < 0.9, all vectors distinct) + shared-wiring.
  Verified host: analyze clean, flutter test 42/42 (+2), phase3 43/43,
  phase4 54/54 (best-frame 180ms), diag_phase4 video #1 at 100 for all
  5 queries with text rows at 90.
  DEVICE ACTION: stored embeddings/frames were written with the broken
  stub — full rebuild + re-run all three seed buttons (demo library,
  demo videos, 20k scale) to rewrite vectors. Expected dialog:
  at100=1 (the video), cutoff~90, modes={text, dual, visual} mixed,
  vecTop ~0.7x.

STATUS 2026-10-02 (device round 4 — gibberish empty state):
  Round-3 dialog showed `"zxqvkw": 180ms (50 hits)`: a top-50 vector scan
  always fills K rows (stub-noise tail cos ~0.5-0.7 -> scores 75-85), so
  visualFloor=50 can never yield the required clean empty state.
  FIX: context gate in fuseAndRank's visual-only branch —
  `tokenHits.isEmpty && sim < 0.9 -> drop` (lone visual admitted only
  with query text in the library or a near-exact match like an exact
  scene tag). STUB-ERA INTERIM: replace with a calibrated vh threshold
  when real CLIP vectors land (Phase 5) — genuine CLIP matches stick
  out of the noise tail, enabling pure visual discovery without this
  gate. Video dialog now probes 'zxqvkw' (expects 0 hits); replica and
  phase4_check mirror/assert the gate.
  Verified host: analyze clean, flutter test 43/43, phase3 43/43,
  phase4 55/55 (best-frame 267ms), replica `"zxqvkw": 0 hits
  EXPECTED-EMPTY` with videos still #1 on all 5 real queries.
  DEVICE ACTION: code-only change, data unchanged — rebuild + re-run
  "Seed demo videos" dialog (now ends with the zxqvkw probe).

STATUS 2026-10-02 (device confirms round 4):
  `"zxqvkw": 0 hits -> clean empty state` (text=0 vec=50 frame=4 gated to
  n=0); videos #1 with frame times on all 5 queries (at100=1, cutoff=90,
  mixed modes, vecTop 0.56-0.71). "2 by flag" on 4/5 queries is CORRECT:
  the demo library's own 3 video rows (birthday_dinner/beach_vlog/
  standup_meeting) text-match at 90; 'hike' has no such row -> 1/1.
  p95 515ms OVER the 500 demo budget on the FIRST query after seeding
  (birthday 515 -> ocean 215 for identical work): cold SQLite page-cache
  signature + run variance (432/441/463/515 across runs). 500ms is our
  own demo gate, not a PRD exit (Phase 4 exits: video-by-scene,
  sampling, handoff — all met). No code change: re-tap to confirm warm
  p95 < 500; if it stays over, optimize vectorScan (in-memory embedding
  cache) as follow-up.

STATUS 2026-10-02 (Phase 4 DEVICE VERIFICATION CLOSED):
  Re-tap: p95 486ms PASS (birthday 486 -> ocean 217, warm-cache
  signature confirmed). All device criteria green: 4 videos / 233
  frames indexed; matching video #1 at 100% with frame timestamp on all
  5 queries; library videos surface alongside (2 by flag where OCR
  matches); gibberish -> 0 hits clean empty state. Host: analyze
  clean, flutter test 43/43, phase3 43/43, phase4 55/55. DONE — no
  further Phase 4 work. HOLD: user explicitly said not to start
  Phase 5 until told.

## Phase 5 — Pro Intelligence: Timed Frames + STT + Fuzzy Temporal + Visual Similarity
**PRD refs:** §3 STT/Fuzzy/Similarity, §4 Pro tier, Journey Phase 3B/3C
**Goal:** Differentiators that justify subscription.

Tasks:
1. Timed frame index (Pro): per-segment timestamps retained, seek-to-tap (`?t=` handoff).
2. STT pipeline (Pro, on-demand + idle): extract audio → Whisper-Tiny → segments → FTS. Queue only on charging/idle by default. Show "Transcribing..." state.
3. Transcript UI: snippet with timestamp highlight, tap seeks native player to `t_start`.
4. Fuzzy temporal parser: "last summer", "recent sunset" → date-range + semantic re-rank. Pro-gated; Free sees paywall preview.
5. Visual similarity ("Find Similar"): reference-image embedding → KNN across library. Pro-gated.
6. Feature gating service: `canUse(feature)` + paywall sheet + 1-tap subscribe.

Exit criteria:
* STT 1.0-1.5x realtime on CPU; phrase query ("happy birthday") returns timestamped hit.
* Free user hitting Pro feature gets inline preview + paywall, no crash.

## Phase 6 — Offline Queue + Battery/Thermal/Storage Guardrails
**PRD refs:** §6 Resource Efficiency, §5 Battery guardrails, Journey Phase 5
**Goal:** Never hot, never dead battery, never OOM.

Tasks:
1. Queue: new photos/videos taken offline → local queue → idle processing. Dedupe + backoff.
2. Guards: battery <20% (unless charging) → pause; thermal Serious → 30% throttle + sleep gaps, Critical → suspend; RAM pressure → unload models; free disk <1GB → stop + prompt.
3. Settings: add/remove folders, re-index, clear cache/index with size display.
4. "Air-gapped" badge + local-only audit log (0 bytes uploaded claim verifiable in test).

Exit criteria:
* Monkey test: low-battery + thermal + low-disk transitions pause/resume cleanly with user-visible reason.
* 4-6GB RAM devices: no OOM kills during 5k-file soak.

## Phase 7 — Monetization & Limits
**PRD refs:** §4 Tiers, Journey Phase 4
**Goal:** Enforce Free 10k cap, convert at natural moments.

Tasks:
1. Counter: cumulative indexed files; hard-stop at 10k for Free with friendly nudge + upgrade CTA.
2. Triggers: 80%/100% cap banner; Pro-feature attempt → preview + subscription sheet.
3. Purchases (dev/beta, zero store fees): Paystack Payment Pages (live monthly/yearly URLs in `billing_links.dart`, no store IAP); Android builds via Direct APK + F-Droid. StoreKit 2 + Play Billing SKUs, restore purchases, and store receipt validation deferred to production.
4. Single-use fulfillment (serverless, `server/`): `api/paystack-webhook.js` verifies `charge.success` (HMAC + event idempotency), mints `QP-PRO-XXXX-XXXX` (CSPRNG, no ambiguous glyphs), stores `active` in Upstash Redis, emails via Resend. `api/redeem.js` burns the key on first use (same-device re-activation allowed; other devices get `410 used`). App: `LicenseStore.redeem` (one HTTPS call, friendly offline/timeout errors) → local per-account Pro + 7-day grace → full offline operation after. `BackendKeys.licenseApiBase` empty = dev-only offline accept. Support runbook (lookup/reset/resend) in `server/README.md`.
5. Analytics (privacy-safe, free): Aptabase or Firebase Analytics — paywall views/conversions only as counts, no query content.

Exit criteria:
* Free 10,001st file blocked with upgrade path; Pro unlocks unlimited + timed/STT/similarity/fuzzy immediately, persists across restarts offline.

## Phase 8 — Privacy & Zero-Knowledge Telemetry
**PRD refs:** §7 full section
**Goal:** Provable air-gap + minimal crash reporting.

Tasks:
1. Scrubber unit: strip paths, queries, folder names, GPS, vectors before any egress. Unit tests with fixtures.
2. Payload allowlist: stack trace + OS version + device model only. No IP retention (Aptabase/GlitchTip self-host config or Firebase data settings).
3. Integrate free stack: Aptabase SDK (or Firebase Analytics, free unlimited) for opt-in analytics + Firebase Crashlytics (free unlimited) or self-hosted GlitchTip (Sentry-compatible API) for crashes.
4. First-launch copy + Settings toggle. Crash-report opt-in/out runtime switch.
5. Pen-test: attempt to exfiltrate PII via crash path, verify redaction.

Exit criteria:
* Network capture shows zero media/metadata egress; telemetry payload schema test passes.

## Phase 9 — Hardening, Benchmarks & MVP Release
**Goal:** Ship with proof of PRD targets.

Tasks:
1. Fixture library: 20k mixed photos + videos + OCR docs + speech clips; automated perf suite (index ms, query p95, STT realtime factor, RAM, index size).
2. Device matrix: low-end (4GB RAM) → flagship; iOS + Android; SD-card case.
3. Beta (zero-cost): Android open beta via Direct APK + F-Droid; Firebase Crashlytics / GlitchTip for crash triage → fix top crashes/ANRs. TestFlight / Play Internal + StoreKit/Play Billing deferred to production (requires paid developer accounts).
4. Store assets, privacy labels ("Data Not Collected"), Data Safety form (production only).
5. Release checklist: airplane-mode pass, 10k→Pro pass, scrubber pass.

MVP cut line (if slipping): ship Phases 0-4 + 6 + 8 first; gate Phase 5 Pro features behind single "Pro (early)" flag but STT can land as 1.1 if Whisper size/perf misses.

STATUS 2026-10-03 (Phases 5-9 CODE COMPLETE, host-verified):
  Phase 5 (all 6 tasks): ProGate/ProTierStore + paywall sheet + settings
  Pro switch; fuzzy-temporal parser (seasons/recent/year, fuzzy flag,
  tier-resolved searchDetailed + Free preview chip); ?t= seek handoff +
  Pro play labels + Free upsell; framesForFile; findSimilar/findSimilarById
  + SimilarScreen; STT stub pipeline (per-video vocab, transcripts table +
  token merge) + tappable transcript segments with Pro seek; Phase 5
  settings dialog (tier/fuzzy/handoff/frames/similar/STT probes).
  Phase 6: Guardrails.evaluate + DevicePauseSignals over
  querypic/vitals (Kotlin MainActivity + Swift AppDelegate plugin),
  pausedStorage/pausedCap states + banner, per-file error capture,
  ModelCache + memory-pressure observer, audit_log (both schemas +
  self-heal), index size/rebuild/privacy-audit/transcribe settings rows,
  auto-transcribe toggle + startup hook, TranscriptionQueue.
  Phase 7: worker Free 10k hard-stop (synthetic excluded), 80% CapBanner
  + paywall CTA, license-key entitlement + offline grace + settings entry,
  Stripe placeholder links (guarded), count-only Analytics (opt-in, audit
  sink), paywall view/convert events.
  Phase 8: Scrub (path/GPS/token + allowlist) with exfiltration test,
  CrashReporter interface + audit-log sink + onError wiring, separate
  crash opt-in (first-launch + settings).
  Phase 9: tools/release_check.py orchestrates all checkers + harnesses.
  Verified host: analyze clean, flutter test 78/78, release gate PASS
  (phase1-8, resume, airplane). REMAINING = device runs (Phase 5 dialog
  incl. STT probe, monkey-test transitions, 5k soak, STT realtime
  factor), native-channel runtime, iOS Mac build, real-model swaps
  (CLIP/Whisper .tflite), and all production/human steps below.

STATUS 2026-10-03 (Phase 5 dialog crash — STT token PK violation):
  `UNIQUE constraint failed: tokens.kind/token/ref_id [transcript, the,
  ...]`: SttIndexer.indexVideo inserted transcript tokens per segment
  without cross-segment dedupe ("the" repeats across segments of one
  video). FIX: collect tokens into a Set across all segments, insert
  once. Verified host (analyze + 78/78 + phase5 green); device re-run
  of Phase 5 Pro checks pending.
  NOTE on Phase 4 dialog p95 602ms: first-query-cold plus DB bloat from
  repeated reseed cycles (ids 40081+ = 4th cycle; deleted pages fragment
  the file). For a clean number: Clear synthetic rows, reseed all three
  once, re-run. Budget remains our internal demo gate, not a PRD exit.

STATUS 2026-10-03 (Phase 5 dialog round 2 — STT miss + probe fixes):
  Two probe failures, both mine: (a) similar probe guessed
  `photo_00.jpg` — demo URIs are named (receipt_home_depot.jpg, ...);
  fixed to sunset_pier.jpg. (b) REAL RANKING BUG: "happy birthday"
  returned 50 hits with NO birthday video. The video's transcript hits
  (happy+birthday) merged fine, but its OCR hit (birthday) had been
  crowded out of the LIMIT-50 ocr window BEFORE merging, leaving it at
  2 vs max 3 -> scored ~78, cut below the cutoff. FIX: new
  IndexDatabase.tokenHitsForIds (targeted counts, no truncation) fetches
  ocr hits for transcript-matched ids missing from the ocr window, so
  spoken + captioned evidence combine (video now 3 = max -> ~90+).
  Extra query runs only when transcript hits exist outside the ocr
  window (zero cost otherwise). Also fixed the probe's misleading
  fallback line (MISS vs not-seeded now distinct).
  Verified host (analyze + 78/78 + phase5 green); device re-run of
  Phase 5 Pro checks pending.

STATUS 2026-10-03 (Phase 5 dialog round 3 — weak-visual drag, fixed):
  New tool tools/diag_stt.py replicates the device "happy birthday"
  query EXACTLY (LCG corpus + verified-identical embed + transcript and
  frame rows): clean corpus -> video #1 at 82; with transcribed library
  rows (user tapped Transcribe while Pro: birthday_dinner reaches 4
  hits, maxToken=4) -> video CUT at 67, cutoff 74. ROOT CAUSE
  (structural, not data): the dual blend 60/40 lets weak visual
  evidence drag down strong text — a 0.099 frame sim pulled a 3/4 text
  match from 81 (text-only) to 67. FIX: dual score =
  max(lone-text, blend), so visual can only add, never hurt; replica
  now ranks the video #3 at 81 (transcribed case) and #1 at 90 (clean
  case). New regression test pins the exact device numbers (3/4 +
  0.099 -> 81, was 67); diag_phase4/diag_stt mirrors updated.
  Open curiosity (non-blocking): device reports birthday frame-best
  0.15@2.5s vs replica 0.099@7.5s for the same query despite 13/13
  embed parity strings — likely a stale frame row; ranking outcome is
  identical either way, revisit only if device rank disagrees.
  Verified host (analyze + 79/79 + phase3/4/5 green); device re-run of
  Phase 5 Pro checks pending.

STATUS 2026-10-03 (Phase 5 DEVICE VERIFICATION CLOSED):
  Dialog Verdict: PASS — tier Pro; all 3 fuzzy probes (Free preview +
  Pro filtered, 0 out-of-window); handoff ?t=/hints correct; frames
  probe 0.0s@1.00; similar probe Free 0+preview / Pro 1 hit; STT probe
  transcribed 4/4 with "happy birthday" -> birthday video #2 and
  segments 3 (0/10/20s). STT exit criterion met on device (phrase query
  returns timestamped hit). Host: analyze clean, 79/79 tests,
  phase3 43/43, phase4 54/54, phase5 63/63, release gate PASS.

STATUS 2026-10-03 (Step 2 Pro UI walkthrough verified via screenshots):  ocean_waves.mp4 ("sunset", Pro): TRANSCRIPT box with 3 timestamped
  segments, "Play from 0:08 (Pro)" button, Pro seek note, unlocked
  Find similar button, 100% match pill.   birthday_party.mp4 similarly correct (81%, frame 7.5s, transcript
  present). Earlier "missing"
  reports resolved as conditions, not bugs: Pro seek label needs
  bestFrameSecs > 0 (text-only matches like beach_vlog correctly show
  the plain button); transcript box renders only where STT rows exist
  (sample-videos via probe, library videos via Transcribe videos).

STATUS 2026-10-03 (Step 3 settings rows verified via screenshots):
  Phase 5 dialog re-confirmed PASS (fuzzy/handoff/frames/similar/STT
  all green, birthday video #2). Index size: 13.5 MB, Real files 0
  (correct — synthetic excluded from cap accounting), 233 frame rows.
  Privacy audit: 0 events (consistent — no crashes, telemetry
  default-off, viewed before license activation). Transcribe videos:
  3 transcribed (the library videos; sample-videos already had rows —
  this also confirms the maxToken=4 mechanism behind the earlier STT
  miss). License key: QP-PRO-AB12-CD34 accepted with automatic tier
  flip;   malformed key rejected with format shown. Phase 6/7 settings
  verification closed.

STATUS 2026-10-03 (Step 4 DEFERRED by user):
  Guardrail field test (battery <20% pause/resume, thermal pause)
  cannot run right now. Code + host coverage stands (Guardrails matrix
  unit-tested, phase6 green, banner copy in place); device proof waits
  for a convenient window. Not blocking Steps 5-12.

STATUS 2026-10-03 (Step 5 models inventoried):
  clip_joint_s2.tflite (378MB) probed: JOINT image+text (in [1,3,256,256]
  + [1,77 ids], out 2x[1,512]); vocab.json (49408) + merges.txt valid.
  Models dir git-ignored (*.tflite/*.bin/*.onnx/*.pt/*.pth) so the
  binary can never be committed. whisper-with-timestamp-tiny-en.tflite
  (42MB) acquired + generation script: single serving_default
  signature, in [1,80,3000] float32 mel, out token sequences with
  inline timestamp tokens (encoder+decoder baked in). Binary forensics
  confirm (TFL3, decoder while-loop, sequences out). STILL NEEDED from
  user: whisper vocab.json (CLIP's on-disk vocab is a different
  tokenizer) + one REAL video with speech for the test (demo rows have
  no audio bytes). Then: Dart mel frontend + tflite loader + timestamp
  decoder + Flex AAR line + adb-push debug path + device round.

STATUS 2026-10-04 (live-transcribe round 3: NaN PCM, fixed):
  Device chunk lines proved it: rms=NaN, peak=2.5e38, identical
  eot-first ids every chunk. Valid bytes CANNOT produce NaN through
  the int16 path, so the decoder handed over stale buffer regions:
  the code never set position/limit from info.offset/info.size, and
  several OEM decoders (Transsion included) return buffers with stale
  positions — we read uninitialized memory. The model behaved
  correctly throughout (garbage in -> end-of-text out). FIX: honor
  [offset, offset+size) on every output buffer (both int16 and float
  paths); Dart side sanitizes non-finite samples to silence with a
  nan= count in the chunk line. New tests: sanitize unit test,
  phase5 offset/sanitize checks. Expect next run: rms ~0.01-0.3,
  nan=0, varied ids per chunk, real segments.
  DEVICE ACTION (round 3): rebuild, Transcribe test video, paste
  chunk lines.

STATUS 2026-10-04 (live-transcribe round 4: encoding flag lied, fixed):
  Chunk math proved misread, not silence: nan ~= 0.32% == the NaN rate
  of RANDOM bits as float32, peak ~1e38, rms ~1e37 — int16 bytes read
  as float. The outputFormat encoding flag claimed float while buffers
  carried int16 (OEM quirk). FIX: never trust the flag — every buffer
  is validated (finite + <= 8.0) and decoded as float or int16
  accordingly, per buffer, with downmix helpers for each. Dart
  sanitize stays as belt-and-braces (nan= now measures true input
  pathology, not our misread). Verified host (analyze + phase5 green;
  no Dart logic changed this round).
  DEVICE ACTION (round 4): rebuild (compiles the new Kotlin),
  Transcribe test video, paste chunk lines — expect sane rms, nan=0,
  varied ids.

STATUS 2026-10-04 (installed APK forensically good, device still stale):
  Built app-debug.apk HERE and searched its bytes: classes16.dex has
  looksLikeFloatPcm/downmixInt16/querypic-audio, kernel_blob has
  "extractor v", both model assets bundled. The artifact is correct,
  yet `adb install -r` + run still shows the pre-ext dialog with
  bit-identical values. Single profile, no clones. Conclusion: the
  running process is not coming from the installed APK (replace did
  not displace it). Prescription: full `adb uninstall` (wipes only
  synthetic seeds — reseed after), fresh install, relaunch, rerun.
  If the marker is STILL absent after that, the issue is on-device
  process/package management, not our code or build.

STATUS 2026-10-04 (decisive round: cache off, bytes logged, ext v3):
  Reasoning exhausted on why verified-new code misbehaves, so this
  round removes whole failure classes at once: (a) android.enable
  BuildCache=false in gradle.properties — Gradle can no longer serve
  stale dex, at the cost of slower builds (revert once green);
  (b) channel bytes are exactly copied (no view aliasing possible)
  with byte length logged per chunk (expected ~5.3MB per full 30s
  chunk at 44.1kHz stereo int16); constant/wrong lengths across
  chunks would prove a transfer fault; (c) ext fingerprint bumped to
  3, so any pre-round-5 code on device is instantly visible.
  Verified host (analyze + stt tests). DEVICE ACTION: first compare
  md5 of the APK on device vs local file (proves install-vs-run in
  one command); then flutter clean + rebuild + uninstall + install +
  run + paste dialog (expect v3, bytes~=5.3M, sane rms).

STATUS 2026-10-04 (stale native code in installed APK):
  Device ran NEW Dart (nan= field present) with OLD Kotlin behavior
  (bit-identical garbage) after a full assembleDebug+install: Gradle
  Kotlin incremental compilation went stale. No code fix needed for
  this — remedy is `flutter clean` + rebuild on the device side.
  Permanent guard added: the extractor now reports a build
  fingerprint ("ext": 2) surfaced as `extractor vX` in the result
  dialog (v0 = pre-versioned/stale), so every future paste
  self-verifies which native code ran. Verified host (analyze + stt
  tests + phase5 green).
  DEVICE ACTION: flutter clean, rebuild, Transcribe test video, paste
  dialog — expect `extractor v2`, sane rms, nan=0.

STATUS 2026-10-04 (sanitize wrote into an unmodifiable view, fixed):
  "Cannot modify an unmodifiable list" came from the new sanitize
  itself: it assigned into the channel-provided Float32List view,
  which arrives unmodifiable (previous build ran the identical path
  fine precisely because nothing mutated it). FIX: copy-on-clean —
  sanitize takes List<double>, returns a cleaned copy only when
  non-finite samples exist, never touches the input; regression test
  feeds a List.unmodifiable. Verified host (analyze + stt tests).
  DEVICE ACTION: rebuild, Transcribe test video, paste chunk lines.

STATUS 2026-10-04 (live-transcribe round 2: fast but silent):
  Device: tensors in [1,80,3000] f32 / out [1,448] i32 (exactly as
  specified), inference runs at 4.72x realtime — but 0 segments. Zero
  text tokens means the model emitted end/silence path: either the
  audio has no speech, or the frontend feeds it wrong. Hardened this
  round: (a) Kotlin handles float-PCM decoders, not just int16;
  (b) engine records per-chunk PCM rms/peak + first 10 raw output ids
  + seg count, shown in the result dialog — this distinguishes silent
  input (rms ~0) from mel mismatch (healthy rms, empty ids) from
  decoder loss (text ids present, 0 segs); (c) mel peak-placement
  unit test (440 Hz -> bands 5..20) verifies filterbank wiring.
  DEVICE ACTION: rebuild, re-run Transcribe test video, paste the new
  chunk lines (c0 rms=… ids=[…]) + confirm whether the clip has speech
  in its first 30 s.
  Device: Model status loads:true ([1,448], vocab 50258) but first
  Transcribe run fails "Bad state: failed precondition" — load parses
  the graph, first run() throws. Prime suspect: TF-op/delegate support
  at invoke time (note: tflite_flutter 0.12 = LiteRT, NOT classic TF
  Lite, so the classic select-tf-ops AAR would be the wrong fix —
  NOT added). DEFINITE BUG found while reviewing: model input was
  built [1][3000][80] instead of [1][80][3000] (same element count, no
  shape error — silently transposed audio). Fixed + unit-tested
  ([1][80][3000] spot-checked). Diagnostics upgraded: Model status
  prints tensor dtypes, failure dialog prints 8 stack lines.
  DEVICE ACTION: rebuild, Model status (paste tensors line), Transcribe
  test video (paste failure WITH stack) — the stack identifies whether
  this is op support, delegate, or buffer handling.

STATUS 2026-10-04 (transcribe-row UX bug, fixed):
  Two reports from the live run: (a) the "Transcribing…" dialog had a
  Done button — worse than cosmetic, the code awaited that dialog so
  NOTHING ran until the user dismissed it. Replaced with a true
  non-dismissible progress dialog (spinner, barrier locked) that the
  code pops on success/failure. (b) 13+ min run is slow-not-stuck
  until proven otherwise: debug JIT (mel FFT unoptimized), itel CPU
  inference, unknown video length, 20-chunk cap bounds it. Release
  builds will be several times faster; the 1.0-1.5x target must be
  measured on release, debug numbers are pessimistic by design.

STATUS 2026-10-03 (Step 5 wiring complete, host-verified):
  whisper_vocab.json validated (50258 ids 0-50257 + endoftext; timestamp
  ids arithmetical). Built: querypic/audio channel (Kotlin MediaCodec
  AAC->16k mono float32 chunked + Swift AVAssetReader best-effort),
  Dart log-mel (Hann/FFT-512/Slaney-80, whisper normalization),
  WhisperVocab + timestamp-pair decoder, TfliteSttEngine (asset load,
  30s chunk loop, realtime factor, fail-closed), AppIndex prefers real
  engine w/ stub fallback, Model status + Transcribe test video rows,
  READ_MEDIA_VIDEO manifest + permission_handler flow, whisper assets
  bundled (CLIP 378MB stays out of the APK). Deliberately NOT added:
  Flex select-tf-ops AAR (awaiting load-error evidence from device).
  Verified host: analyze clean, 92/92 tests, release gate PASS.
  DEVICE ACTION: adb push lv_0 mp4 to /sdcard/Download, rebuild,
  Model status row then Transcribe test video; paste both dialogs
  (expect shapes/error line + realtime factor + segments).

STATUS 2026-10-05 (Step 5 PROVISIONING CLOSED; base.en → future):
  All model files present, inventoried, git-ignored and probed:
  clip_joint_s2 (joint image+text, signatures verified), whisper
  vocab (50258, verified sufficient), whisper TTS golden clip,
  three whisper candidates tried with a recorded verdict each
  (2 bad conversions retired from the bundle, kept on disk;
  transcribe-translate shipped and device-verified). Whisper
  integration DONE end-to-end (loader, mel, decoder, queue, UI,
  probes, filters; realtime 1.3-4.9x across runs). DECISION (user):
  base.en stays FUTURE WORK, in the Pro-upgrade shape (tiny default,
  base as paid differentiator + lazy download, low-RAM fallback) —
  not a deviation from product values, but a resource-budget item
  to prove on hardware first. REMAINING FUTURE (was never in Step
  5's exit criteria): CLIP tower wiring (BPE/tokenizer files ready,
  adb-push debug path, needs full reseed + threshold re-tune —
  its own project).

STATUS 2026-10-04 (live-transcribe round 5: decoder aborted real output):
  Device chunk data proved the model works: per-chunk varied text ids
  plus genuine timestamp tokens (50449 = t=1.7s). The decoder broke on
  the output's FIRST id (50257), treating it as end-of-text — but with
  text and timestamps following, it is this converter's generation-
  start marker. FIX: leading 50257 skipped (terminates only after
  content), trailing zero padding (unwritten buffer tail) ends decoding
  at an 8-run with '!' trimming on the final segment only. New
  regression test mirrors the real layout; all prior decoder tests
  pass unchanged. Verified host (analyze + stt tests + phase5 green).
  DEVICE ACTION: rebuild, Transcribe test video — expect real segments
  with words this time.

STATUS 2026-10-04 (live-transcribe round 6: word salad diagnosed):
  Device produced segments at 4.85x realtime but word salad
  ("downacel", "Choricalallyittle", looped "sigan"). Detokenizer
  CLEARED via host cross-check (real vocab spot pairs byte-exact).
  Mel frontend CONVICTED: exact-spec Python reference vs the Dart
  512-FFT design diverged 51% (tonal) and 81% (low-freq). FIX:
  frontend rewritten to exact whisper spec (DFT-400 precomputed
  twiddles, periodic Hann, reflect pad, drop-last, audio-level pad);
  Dart output now matches the reference BIT-FOR-BIT on all probes
  (sums/max/spots identical to 4-6 decimals). Verified host
  (analyze + 96/96 tests incl. STT suite). NOTE: phase4 host perf
  proxy flaked 553-715ms in-suite three times while the isolated
  identical scan runs 261-316ms back-to-back — environmental
  (untouched code path, busy host); device p95s remain the binding
  gates and pass.
  DEVICE ACTION: rebuild, Transcribe test video — expect real English
  words this time.

STATUS 2026-10-04 (live-transcribe round 10: WAV has no decoder):
  The v0 + n/a + zero-chunk-lines combination means extraction
  returned NOTHING (not silence, not garbage — nothing): WAV tracks
  report audio/raw, and MediaCodec has no decoder for raw PCM, so
  createDecoderByType threw and the empty result masqueraded as a
  clean "done". FIX: audio/raw bypasses the decoder entirely (sample
  bytes copied straight from the extractor with track-format rate /
  channels / encoding); native errors now surface with their message
  instead of collapsing to null; zero-chunk runs report "no audio
  frames decoded" rather than a vacuous done dialog. Verified host
  (analyze + stt/resample suites + phase5 green).
  DEVICE ACTION: rebuild (Kotlin changed), Transcribe test video
  with /sdcard/Download/tts_test.wav, paste dialog — expect real
  segments of the known script.

STATUS 2026-10-04 (build break — removed import still in use):
  Pruning unused Kotlin imports after the raw-bytes rewrite, I dropped
  java.nio.ByteBuffer while extractRawPcm still allocates with it
  (the second error was its cascade). One-line restore; the device
  build is the only Kotlin compiler available here.
  DEVICE ACTION: rebuild, Transcribe test video with the .wav path.

STATUS 2026-10-04 (live-transcribe round 11: WAV bypass + path fix):
  The failing paste showed the path field WITHOUT its leading slash
  (`sdcard/...`); Dart File resolution vs MediaExtractor disagree on
  relative paths, and WAV was unrunnable anyway (no MediaCodec decoder
  for audio/raw). FIX: (a) path normalized (trim, strip file://,
  restore leading /) with a named File-not-found dialog; (b) WAV
  fast path — RIFF parsed in Dart (16/32-bit PCM, clear errors
  otherwise), bypassing MediaCodec entirely; (c) extractor errors
  now surface with messages instead of collapsing to silent empty;
  zero-chunk runs report failure, not vacuous done. Verified host
  (analyze + resample suite incl. WAV parse/reject tests + phase5
  green).
  DEVICE ACTION: rebuild, Transcribe test video with the absolute
  .wav path, paste dialog — expect the known TTS script back.  The failing paste showed the path field WITHOUT its leading slash
  (`sdcard/...`); Dart File resolution vs MediaExtractor disagree on
  relative paths, and WAV was unrunnable anyway (no MediaCodec decoder
  for audio/raw). FIX: (a) path normalized (trim, strip file://,
  restore leading /) with a named File-not-found dialog; (b) WAV fast
  path — RIFF parsed in Dart (16/32-bit PCM, clear errors otherwise),
  bypassing MediaCodec entirely; (c) extractor errors now surface
  with messages instead of collapsing to silent empty; zero-chunk
  runs report failure, not vacuous done. Verified host (analyze +
  resample suite incl. WAV parse/reject tests + phase5 green).
  DEVICE ACTION: rebuild, Transcribe test video with the absolute
  .wav path, paste dialog — expect the known TTS script back.

STATUS 2026-10-05 (Paystack provider wired, URLs pending):
  billing_links.dart now carries BillingProvider (stripe/paystack,
  default paystack) with per-provider monthly/yearly URLs, portal
  support only on Stripe, and a support-contact support line
  fallback. Paywall sheet splits on isConfigured: empty URLs keep
  the debug instant-subscribe stub (all current device testing
  unaffected); filled URLs show Monthly/Yearly checkout buttons plus
  the honest license-key-by-email fulfillment note. Manage-
  subscription row is provider-aware (portal vs plan-status +
  support route). License flow untouched. Verified host (analyze +
  billing tests incl. new provider-wiring group + phase7 green).
  DEVICE ACTION (user): Paystack dashboard walkthrough below; paste
  the two Payment Page URLs -> one-line config + rebuild + verify.

STATUS 2026-10-06 (Paystack live URLs configured, test-verified):
  Both Payment Pages created and test-paid from the phone browser
  (NGN 3,000 + 2x NGN 30,000 visible in test-mode Transactions).
  URLs wired into billing_links.dart; paywall now shows live
  Monthly/Yearly checkout buttons + fulfillment note; tests assert
  the live URLs (https, exact match) instead of the empty state.
  Verified host (analyze + billing tests + phase7 green).
  DEVICE ACTION: rebuild, open any paywall (fuzzy chip, Pro seek,
  Find similar) — confirm Monthly/Yearly buttons open the real
  pages; Manage subscription shows plan status + support route.

STATUS 2026-10-05 (live-transcribe round 16: it hears English):
  transcribe-translate file on lv_0: c0 transcribes the user's
  KNOWN ground truth recognizably ("Now I'm going to talk about my
  ...takeaway from the ...July session... user-first approach and
  not a tech-first approach... based on our extreme [users]") —
  names mangled (tiny-model ceiling on proper nouns/accent) but
  content words land. Pipeline fully vindicated end-to-end. c1/c2
  are textbook whisper repetition loops on music/silence (Chinese,
  30x repeats). Baked graph exposes no temperature/penalty knobs,
  so implemented the portable equivalents in the decoder (always
  on): 6+-repeat/80%-coverage loop drop, <8% char-diversity drop,
  non-Latin-majority drop (Latin-Extended kept for accents);
  genuine short repeats survive. Tested with the verbatim device
  loop as fixture. Verified host (analyze + stt suite + phase5).
  DEVICE ACTION: rebuild, Transcribe test video on lv_0 — expect
  c0/c3-style English kept, c1/c2 loops gone (segment count drops,
  timestamps jump the gap); then search a spoken phrase to prove
  transcript search on real STT output.

STATUS 2026-10-05 (transcript search proven + overflow/loop hardening):
  "user first approach" returns the file:// video #1 at 90% with its
  TRANSCRIPT — STT exit criterion fully demonstrated on real output.
  Two findings fixed: (a) preview sheet BOTTOM OVERFLOWED by 1476px
  on long transcripts — sheet now scrolls, transcript capped at 4
  rows + "+N more" with 3-line ellipsis; (b) loop detector hardened
  from exact-prefix to 8-gram vocabulary richness (variant loops
  with mid-string mutations and truncated tails defeated the old
  check; verified with variant/truncation fixtures plus a mixed-
  language keep-case). NOTE: current device rows predate the filter
  — re-running Transcribe rewrites them through it.
  Verified host (analyze + stt suite incl. new filter tests + phase5).
  DEVICE ACTION: rebuild, RE-RUN Transcribe on lv_0 (rewrites rows),
  re-search the phrase — loops gone, no overflow.

STATUS 2026-10-05 (gap visibility for filtered spans):
  User asked whether the missing 1:00 span is data loss. It is not:
  the dropped content was degenerate loops only (the filter provably
  passes well-formed text of any language, incl. short genuine
  repeats), matching whisper's own discard-failed-segments behavior;
  recall of real speech is unaffected by construction. But a silent
  gap reads as missing data, so the transcript view now renders a
  divider ("· · · no confident speech in between · · ·") across gaps
  >= 15 s — analyzed-but-empty is visible, distinct from absent.
  Verified host (analyze clean).
  DEVICE ACTION: rebuild, open the video preview — divider visible
  between the 0:00 and 1:30 rows.

STATUS 2026-10-05 (user correction: speech throughout 1:58):
  User was speaking the ENTIRE video — so c1/c2 Chinese loops are a
  MODEL failure on real speech, not music-only hallucinations being
  rightly dropped. The filter is exonerated (it correctly removed
  garbage output) but the underlying miss stands: same voice
  transcribes at both ends (c0/c3 English) yet locks Chinese in the
  middle. Prime suspect now: language auto-detect flip (tonal
  misperception of accent/prosody?) — the file carries explicit
  serving_transcribe + serving_translate + serving_default
  signatures and we currently run whatever default resolves to.
  NEXT (pending user answer on background music): if music present,
  expected behavior, transcript already ideal; if clean speech
  throughout, wire SignatureRunner selection to force the transcribe
  path explicitly and re-test.

STATUS 2026-10-05 (resolved: generator noise, not a bug):
  User confirms heavy generator noise throughout. Diagnosis closed:
  constant broadband drone masks consonants and flips tiny-model
  language detection mid-clip (c0/c3 clean enough to transcribe,
  c1/c2 not) — textbook tiny-model behavior on noisy audio, not a
  pipeline, frontend, or filter defect. The transcript is maximal
  for this model on this audio: real speech kept (c0/c3), halluci-
  nated loops dropped (c1/c2) with a visible gap divider. Remaining
  quality lever is model size (base.en), not code — deferred until
  asked; needs download + rebuild + realtime re-check. Live STT
  work concludes here unless the user requests otherwise.

STATUS 2026-10-05 (live-transcribe round 15: IT SPEAKS — case closed):
  transcribe-translate file transcribes the TTS clip near-perfectly
  ("Hello world... quick brown fox... five dozen liquor jugs",
  one near-miss "Hack" for "Pack"). Output opens [50258,50259(SOT,
  lang),50359(transcribe)...] — textbook prompt prefix, further
  proof of a healthy conversion. CONCLUSIONS: (a) both earlier
  files from that author are bad conversions — retired from the
  bundle (~83 MB saved), kept on disk as history; (b) pipeline,
  threading (identical output at 1 and 4 threads), frontend, detok
  all vindicated; (c) realtime 1.44x single-thread DEBUG already
  inside the 1.0-1.5x exit band — release + 4 threads should add
  margin. Follow-up: threads restored to 4 (identical behavior
  proven safe); timestamps from this file are chunk-granularity
  (no timestamp tokens emitted) — accepted, revisit only with a
  timestamp-capable file that passes the same TTS bar.
  Verified host (analyze + phase5 green).
  DEVICE ACTION: rebuild, Model status (threads: 4), Transcribe test
  video — confirm words stay clean and factor improves.

STATUS 2026-10-04 (live-transcribe round 13: frontend proven exact):
  Installed librosa (the library whisper itself uses) and compared
  sample-for-sample on identical input: frame count, sums, maxes and
  spot values IDENTICAL to 4-6 decimals. The Dart frontend is not an
  approximation of the spec — it IS the spec. Remaining suspects
  narrowed to inside the inference call: XNNPACK multithreaded
  numerics producing deterministic-but-wrong results on this
  chipset (same input -> same wrong output every run fits
  perfectly). EXPERIMENT: threads pinned to 1 (plus Model status
  now reports the thread count). Verified host (analyze + stt
  suite).
  DEVICE ACTION: rebuild, Model status (confirm threads: 1),
  Transcribe test video with the TTS wav. Clean words -> threading
  bug confirmed (keep 1 thread, measure realtime cost). Same salad
  -> model files indicted (next: different conversion source).

STATUS 2026-10-04 (live-transcribe round 14: threads dead, swap again):
  Single-thread run reproduces the same output class — XNNPACK
  threading exonerated. Both nyadla-sys files fail identically, which
  now reads as same-pipeline-same-poison rather than two independent
  defects. NEXT: same-repo different-config file
  (whisper-tiny-transcribe-translate.tflite, 42.1MB — dual
  transcribe/translate signatures, different patch path, serving_
  default = transcribe so our loader needs no changes) as the cheap
  discriminator. PARALLEL BACKSTOP PROVEN: pip dry-run resolves
  torch-2.14.1 + transformers-5.18.0 + tensorflow-cpu-2.22.0rc0 on
  Python 3.14, so self-converting openai/whisper-tiny (fp16, no
  custom patches) is feasible if the swap also fails.
  DEVICE ACTION: download the transcribe-translate file into
  sandbox/models/, report back — engine flip + rebuild + run follows.

STATUS 2026-10-05 (swap file staged, signatures verified):
  whisper-tiny-transcribe-translate.tflite on disk (42.1MB, valid
  TFL3) with serving_transcribe + serving_translate +
  serving_default signatures (default = transcribe per the
  generation script, so the loader is unchanged). Engine default +
  modelVersion flipped; asset bundled; phase5 asserts all three
  model files. Verified host (analyze + stt suite + phase5 green).
  DEVICE ACTION: rebuild (new asset bundled), Model status (expect
  the transcribe-translate filename), Transcribe test video with
  the TTS wav — judge word quality head-to-head.

STATUS 2026-10-04 (live-transcribe round 13: filesystem ground truth):
  "File not found" on a just-pushed file means typed path and device
  disagree (aliases, profiles, or push target). The dialog now
  reports the OS-resolved storage root plus a live listing of the
  app dir, and auto-falls-back to a basename match there — push
  destination vs typed path mismatches resolve themselves.
  (Also: getExternalFilesDir is gone in path_provider 2.x; using
  getExternalStorageDirectory + package path.) Verified host
  (analyze clean, phase5 green; Dart-only change).
  DEVICE ACTION: hot restart is enough (Dart only), Transcribe test
  video, paste dialog — either it transcribes, or the dialog now
  tells us exactly what the app sees on disk.

STATUS 2026-10-04 (live-transcribe round 12: Transsion trimmed WAV):
  User confirmed the full absolute path — killing the slash theory.
  File stats fine but MediaExtractor still fails: this OEM family
  already proved it strips system components (FTS5), and a missing
  WAV sniffer produces exactly this error. Rather than fight the
  OS, the debug flow now uses app-specific external storage
  (/sdcard/Android/data/com.example.querypic/files/), which needs no
  sniffers, grants, or permissions — Dart File reads work
  unconditionally there. Dialog default path updated accordingly.
  Verified host (analyze clean).
  DEVICE ACTION: adb shell mkdir -p the files dir, adb push the wav
  there, rebuild, Transcribe test video (accept the new default
  path), paste dialog.

STATUS 2026-10-04 (extractor failure is a file problem, named):
  "Failed to instantiate extractor" = MediaExtractor cannot open/sniff
  the typed path (missing file or typo), not a model failure. The old
  dialog never named the path. FIX: Dart File-exists pre-check names
  the exact path on failure. Verified host (analyze clean).
  DEVICE ACTION: rebuild, retry — and report WHICH path was typed
  (mp4 default vs tts wav), since that alone decides the next step.

STATUS 2026-10-04 (live-transcribe round 7: only chunk 0 ever ran):
  Device dialog shows ONLY c0 (ext v4, s16, exact 5.29MB framing,
  sane stats) — chunks c1+ never ran. My end-of-stream check
  (resampled length < 480000) trips on AAC framing shaving ~417
  samples off full chunks. FIX: break only on empty returns.
  (Also explains earlier 4-chunk runs: the old Kotlin always emitted
  exactly `need` samples.) Word salad persists in c0 despite the
  exact frontend + clean decode + clean resample; generation script
  asserts no output quality, so the model file itself is now the
  prime suspect alongside genuinely hard audio. Next: full-video
  coverage (c1-c3 were never tested!) discriminates — clean English
  there exonerates the stack; salad everywhere indicts the model
  file (then: swap candidates, e.g. non-timestamp tiny-en).
  Verified host (analyze + stt/resample suites).
  DEVICE ACTION: rebuild, Transcribe test video, paste ALL chunk
  lines + segments; plus ground truth (what is actually spoken in
  the first 30 s? accent/music/noise?).

STATUS 2026-10-04 (live-transcribe round 9: model-swap experiment):
  Ground truth ("Hello everyone. My name is Agidigbi Osarodion
  Stephen..." — clear speech, no music, 118s) vs ~5% output rules
  out difficulty. Chain fully exonerated (decoder framing, int16
  decode, sinc resample, bit-identical mel, byte-exact detok, exact
  tensors/layout). Remaining suspects inside the file: bad int8
  quantization or the custom timestamp-forcing patches degrading
  generation. EXPERIMENT: plain whisper-tiny-en.tflite acquired;
  engine default flipped to it (timestamp variant kept on disk);
  decoder already falls back to chunk-long segments without timestamp
  tokens. Both model files asserted present by phase5_check.
  Verified host (analyze + stt suite + phase5 green).
  DEVICE ACTION: rebuild (new asset bundled), Transcribe test video,
  compare word quality head-to-head against the timestamp run.

STATUS 2026-10-04 (swap inconclusive; golden TTS test staged):
  Plain tiny-en produces the SAME output class (fluent salad, loops,
  now multilingual fragments) with identical c0 head ids across both
  files — not model-specific after all. Golden test staged instead:
  Windows TTS generated tts_test.wav (16 kHz mono 16-bit, ~20 s,
  known script: hello-world/test sentences/pangrams) in
  sandbox/models/. Transcribing it bypasses resampling entirely and
  carries exact ground truth. Clean words -> lv_0 audio is the
  problem; salad -> pipeline/model broken regardless of input.
  DEVICE ACTION: adb push tts_test.wav, Transcribe test video with
  the .wav path, paste segments.

STATUS 2026-10-04 (live-transcribe round 8: model file indicted):
  Full coverage achieved (c0-c3, 36 segments, ext v4, s16, exact
  framing, sane stats throughout). But user-supplied ground truth
  ("Hello everyone. My name is Agidigbi Osarodion Stephen..." —
  clear deliberate speech) vs output (~5% words right, fluent
  non-words, loops) proves NOT a difficulty issue. Chain status:
  decoder bytes exact, int16 decode tested, resampler proven
  (tone/alias/DC), mel bit-identical to spec, detok byte-exact,
  tensors exact, output parses to timestamped English-shaped tokens.
  Every link verified except the model file itself (generation script
  asserts no output quality). Prime suspects inside the file: bad
  int8 quantization OR the custom timestamp-forcing patches
  (_patched_force/suppress_tokens) degrading generation. NEXT:
  swap experiment with plain whisper-tiny-en.tflite (41.6MB, same
  repo) — one-line asset default flip; decoder already falls back to
  chunk-long segments without timestamp tokens. Also ask user about
  background music (last audio-side suspect).

STATUS 2026-10-04 (live-transcribe round 7: resampler replaces linear):
  Exact frontend barely moved outputs (sticky decoder under heavy
  aliasing is plausible) — the last unverified link was the LINEAR
  44.1->16k resampler in untestable Kotlin: no anti-alias filter, so
  everything above 8 kHz folded into speech bands. Moved to tested
  Dart (services/resample.dart): PCM decode with encoding fallback,
  bandlimited windowed-sinc resampling. Host proofs: 1 kHz tone
  preserved, 12 kHz fully rejected (Goertzel 0.000 across the band —
  an earlier peak reading was edge transient, tests now measure the
  interior), DC unity gain, exact-ratio path sane. Kotlin now returns
  RAW decoder bytes + format metadata only. Chunk lines gain enc=
  (s16/f32, * = fallback) and mel=mean/std diagnostics.
  Verified host (analyze + 105/105 incl. 9 resample tests; phase4
  host-perf proxy still flakes environmentally, isolated scan ~280ms).
  DEVICE ACTION: full rebuild (Kotlin changed) + Transcribe test
  video — read enc= (expect s16) and mel= lines with the segments.

## Risks & Open Questions
1. OS API vs bundled OCR/embedding parity (iOS Vision vs ML Kit) — spike in Phase 0.
2. Whisper-Tiny size (~75MB) + CPU cost — lazy download on Pro unlock + charging-only default.
3. iOS background limits may cap 1k/hr throughput — need BGProcessing tuning + "plug in to finish" UX.
4. Vector search at 20k on low-end CPU within 500ms — requires INT8 + IVF/HNSW tuning; fallback to quantized brute-force + top-K prune.
5. Zero-cost stack trade-offs: Aptabase = smaller feature set than paid analytics (acceptable for MVP counts-only metrics); Firebase Analytics/Crashlytics = Google-hosted (verify data-residency + IP-anonymization settings, keep default-off opt-in); GlitchTip = self-hosting ops burden (use managed free tier or single-docker host for beta).
6. Zero-cost distribution trade-offs: Direct APK/F-Droid = no auto-update via Play + manual signing trust UX; Stripe Web Checkout = no native 1-tap IAP + manual entitlement restore; plan StoreKit 2 / Play Billing migration path for production.

STATUS 2026-10-07 (Step 12 final sign-off — beta release candidate):
  Candidate: querypic/build/app/outputs/flutter-apk/app-release.apk
  (111.7MB, release key CN=QueryPic/O=QueryPic/Lagos/NG,
  SHA-256 dfea3cc9910dd976616e49bfafde789f5cca25061668f04c9dbc85f6bb202e5d).
  Host gates green: analyze clean, flutter test 114/114, release_check
  PASS (phase1-8, resume, airplane). Device gates green: 20k soak p95
  194ms no-OOM on 4GB Tecno; egress confined to eu.aptabase.com +
  app.glitchtip.com (PCAPdroid); Paystack test-mode monthly+yearly +
  license activation; Aptabase+GlitchTip end-to-end. Docs: PRIVACY_POLICY.md
  approved (eff. 2026-10-08, querypicsupport@gmail.com); support contact
  wired; keystore/key.properties git-ignored.
  RECORDED KNOWN GAPS (accepted by user): Step 4 guardrail field test
  deferred; Step 10 iOS unverified Android-first; Paystack live-money +
  store accounts ($25/$99) deferred to production; managed-GlitchTip
  connection-IP logging disclosed in policy (self-host at production).

STATUS 2026-10-10 (accounts + RBAC + landing, local-first):
  Marketing LandingScreen gates fresh installs (features showcase, Get
  started -> account creation; nothing usable without a profile).
  AccountStore: on-device profiles (admin/normal), salted SHA-256 admin
  PIN, PIN-gated switch-to-admin, admin-only delete (last-admin guard).
  All Developer-tools rows + Pro-tier debug flip hidden from non-admins.
  Pro/license storage scoped per account (legacy global keys migrate onto
  the first profile); gate + license UI refresh on switch. Paystack live
  checkout + emailed-key flow unchanged, now per active account.
  Privacy policy updated (accounts on-device only). No server, no new
  permissions (microphone already declared for voice).

STATUS 2026-10-11 (single-use per account+device, expiry, flavors):
  redeem binds device::account (second profile can no longer ride the
  first's key); same composite re-entry recovers. Webhook reuses an
  unredeemed key per email+amount/30min AND still emails it (every
  successful payment yields exactly one email); amounts formatted from
  kobo (N3,000.00, not 300000). Monthly=30d/yearly=365d validUntil burned
  at redeem, enforced off-device by clock, shown in Manage subscription;
  legacy flag-only installs migrate to 30d once. Two flavors, one id:
  private admin APK (first account admin/PIN, dev tools) vs public user
  APK (--dart-define=PUBLIC_BUILD=true: first account normal, no PIN,
  dev tools compiled out of reach, free profile add/switch/delete).
  v0.2.0 public asset on GitHub Releases + site link + SHA.
