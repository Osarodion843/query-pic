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
* **Billing:** StoreKit 2 + Google Play Billing for Pro subscription. Entitlement stored locally + store receipt.
* **Telemetry:** TelemetryDeck or self-hosted Sentry, behind on-device scrubber. Opt-in at first launch.

---

## Phase 0 — Foundation & Scaffolding
**PRD refs:** §5 Architecture, §7 Privacy
**Goal:** Runnable skeleton on both OSes with sandbox DB, CI, and model harness.

Tasks:
1. Init Flutter project (or dual-native if chosen), lint, CI build for iOS/Android.
2. Define sandbox storage layout: `/models/`, `/db/index.db`, `/thumbs/`, `/queue/`.
3. SQLite schema v1: `files(id, uri, type, mtime, w,h,duration, hash)`, `embeddings(file_id, vec_int8, model_ver)`, `ocr(file_id, text)`, `frames(file_id, t, vec)`, `transcripts(file_id, t_start, t_end, text)`, `fts` virtual table.
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
3. Purchases: monthly/yearly SKUs, restore purchases, offline entitlement grace, receipt validation.
4. Analytics (privacy-safe): paywall views/conversions only as counts, no query content.

Exit criteria:
* Free 10,001st file blocked with upgrade path; Pro unlocks unlimited + timed/STT/similarity/fuzzy immediately, persists across restarts offline.

## Phase 8 — Privacy & Zero-Knowledge Telemetry
**PRD refs:** §7 full section
**Goal:** Provable air-gap + minimal crash reporting.

Tasks:
1. Scrubber unit: strip paths, queries, folder names, GPS, vectors before any egress. Unit tests with fixtures.
2. Payload allowlist: stack trace + OS version + device model only. No IP retention (server config).
3. First-launch copy + Settings toggle. Crash-report opt-in/out runtime switch.
4. Pen-test: attempt to exfiltrate PII via crash path, verify redaction.

Exit criteria:
* Network capture shows zero media/metadata egress; telemetry payload schema test passes.

## Phase 9 — Hardening, Benchmarks & MVP Release
**Goal:** Ship with proof of PRD targets.

Tasks:
1. Fixture library: 20k mixed photos + videos + OCR docs + speech clips; automated perf suite (index ms, query p95, STT realtime factor, RAM, index size).
2. Device matrix: low-end (4GB RAM) → flagship; iOS + Android; SD-card case.
3. Beta: TestFlight + Play internal → fix top crashes/ANRs.
4. Store assets, privacy labels ("Data Not Collected"), Data Safety form.
5. Release checklist: airplane-mode pass, 10k→Pro pass, scrubber pass.

MVP cut line (if slipping): ship Phases 0-4 + 6 + 8 first; gate Phase 5 Pro features behind single "Pro (early)" flag but STT can land as 1.1 if Whisper size/perf misses.

## Risks & Open Questions
1. OS API vs bundled OCR/embedding parity (iOS Vision vs ML Kit) — spike in Phase 0.
2. Whisper-Tiny size (~75MB) + CPU cost — lazy download on Pro unlock + charging-only default.
3. iOS background limits may cap 1k/hr throughput — need BGProcessing tuning + "plug in to finish" UX.
4. Vector search at 20k on low-end CPU within 500ms — requires INT8 + IVF/HNSW tuning; fallback to quantized brute-force + top-K prune.
