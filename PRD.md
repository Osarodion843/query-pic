# Product Requirements Document (PRD)

**Product Name:** QueryPic  
**Version:** 1.0 (MVP)  
**Target Platforms:** iOS & Android  
**Product Vision:** A privacy-first, 100% on-device search utility for mobile devices that enables everyday consumers to find specific photos and video clips using natural language, OCR text recognition, visual similarity matching, and spoken audio transcription.

---

## 1. Target User & Pain Point

* **Primary Persona:** Everyday smartphone users managing large, unorganized personal photo and video libraries stored on local device storage or SD cards.
* **Core Pain Point:** Traditional mobile gallery apps rely solely on chronological dates or manual tagging. Users struggle to locate specific memories, document scans, or spoken dialogue buried inside lengthy video recordings without manual scrolling.

---

## 2. User Experience & Interface (Hybrid Model)

* **Initial Launch Screen:** Opens directly to a clean, quick-search home screen featuring a prominent natural language search bar accompanied by dynamic filter chips (*"Receipts"*, *"Videos with Speech"*, *"Recent Sunset"*).
* **Expanded Media Workspace:** Submitting a query or selecting a filter chip expands into a full gallery view displaying thumbnail grids, visual match scores, and a preview modal.
* **Native Video Player Handoff:** Tapping a video search result automatically launches the video in the mobile operating system's native video player.

---

## 3. Core Features & Functional Requirements

### Search Intelligence Engine
* **Multi-Modal Recognition:** Detects objects, actions, scene contexts, visual compositions, and embedded text (OCR).
* **Audio & Speech-to-Text (Video):** Transcribes audio tracks within locally stored videos using a lightweight on-device Speech-to-Text engine, enabling keyword search across spoken dialogue.
* **Fuzzy Temporal Queries:** Interprets relative natural language date expressions combined with semantic context (e.g., *"beach sunset from last summer"*).
* **Visual Similarity Search:** Performs vector matching against a reference image to locate visually similar media across the library.

### Storage & Scope Controls
* **Directory Scoping:** Users explicitly pick which folders/directories QueryPic is permitted to scan, avoiding forced full-disk crawls.

---

## 4. Monetization & Feature Tiers

| Feature | Free Tier | Pro Tier (Subscription) |
| :--- | :--- | :--- |
| **Local Indexing Limit** | Cumulative cap of up to 10,000 total files | Unlimited local files |
| **Visual Search Capabilities** | Objects, Scenes, OCR Text | Objects, Scenes, OCR Text |
| **Video Search** | Thumbnail & object match | Timed frame search + Speech-to-Text transcription |
| **Advanced Tools** | Basic date filters | Visual Similarity Search + Fuzzy Temporal queries |

### Distribution & Monetization (Development Phase, zero-cost)
* **No mandatory store fees during prototyping / open beta:** bypass the $99/year Apple Developer and $25 Google Play registration fees.
* **Android:** distribute via Direct APK download and F-Droid (both free, no registration fee).
* **Pro checkout (dev/beta):** Web Checkout via Stripe API (no store IAP dependency) for Pro unlock; StoreKit 2 + Google Play Billing deferred to production release only.

---

## 5. Technical & Performance Benchmarks

### Architecture & Hardware Compatibility
* **100% On-Device:** Executes quantized machine learning models (CoreML / TFLite / ONNX) locally on the device.
* **CPU Compatibility:** Fully optimized for standard mobile CPUs; does not require specialized Neural Processing Units (NPUs).

### Processing & Latency Targets
* **Image Indexing:** 200–400 ms per photo on standard hardware (~1,000–1,500 photos/hour in background idle mode).
* **Video Frame Sampling:** Extracts and analyzes 1 frame every 2–3 seconds of video footage.
* **Speech-to-Text:** Transcribes audio at ~1.0x–1.5x real-time speed on mobile CPU.
* **Query Latency:** Sub-500 ms query response time across an indexed library of 20,000 files.

---

## 6. Offline Performance Expectations

### Network Independence
* **Zero Cloud Dependency:** Search models (CLIP/MobileViT, OCR, Whisper-Tiny) and vector databases run completely inside the local app sandbox.
* **Feature Parity Offline:** Search accuracy, response speed, and filtering function identically in Airplane Mode or offline environments.

### Query & Search Execution
* **Sub-500ms Vector Match:** Natural language vector similarity matching completes in under 500ms across 20,000 local indexed files.
* **Instant Filter Execution:** OCR text lookup and EXIF date filtering complete in under 100ms.

### Resource Efficiency & Guardrails
* **Quantized Storage Footprint:** 8-bit vector compression keeps index storage light (~15MB–25MB per 10,000 files).
* **Dynamic RAM Management:** AI models load on-demand during active queries/background processing and unload immediately when idle to prevent low-memory crashes on 4GB–6GB RAM devices.
* **Battery & Thermal Guardrails:** Background scanning, frame extraction, and speech transcription pause instantly if battery drops below 20% or thermal throttling occurs.

### Asynchronous Offline Queueing
* Photos and videos taken offline are queued locally and processed incrementally during background idle times without server dependencies.

---

## 7. Privacy & Data Architecture

* **Air-Gapped Indexing:** All vector embeddings, OCR logs, transcriptions, and metadata reside exclusively in the app’s local sandboxed directory.
* **Sanitized Zero-Knowledge Telemetry:**
  * **Automatic Bug Detection:** Sends anonymized crash logs without requiring manual user support tickets.
  * **On-Device Data Scrubbing:** Pre-filters remove file paths, search queries, folder names, location coordinates, and image vectors before transmission.
  * **Transmitted Data:** Purely technical stack traces, OS version, and hardware model.
  * **Identity Decoupling:** Uses 100% free / open-source analytics infrastructure with zero persistent user tracking or IP retention:
    * **Telemetry & Analytics:** Aptabase (open-source, privacy-first mobile analytics) or Firebase Analytics (free unlimited tracking).
    * **Crash Reporting:** Firebase Crashlytics (free, unlimited crash reporting) or GlitchTip (open-source, lightweight Sentry-compatible error tracker).
* **First-Launch Transparency:** An explicit setup screen informs users that all media processing is 100% local and requests permission for anonymous technical error reporting.