# QueryPic

> **Privacy-First, 100% On-Device Multi-Modal Media Search Utility for Mobile (iOS & Android)**

QueryPic empowers everyday mobile users to instantly find photos and video clips using natural language queries, optical character recognition (OCR), visual similarity matching, and on-device video speech transcription—without any user data ever leaving the device.

---

## 🚀 Key Features

* **Natural Language Search:** Find photos and videos using intuitive descriptions (e.g., *"Beach sunset from last summer"* or *"Receipt from Home Depot"*).
* **100% On-Device & Air-Gapped:** All ML inference, vector embeddings, OCR indexing, and speech transcriptions execute strictly on-device. Zero cloud uploads.
* **Video Speech-to-Text Transcriptions:** Transcribes audio tracks of stored videos using a lightweight local STT engine to allow keyword search across spoken dialogue.
* **Timed Video Result Handoff:** Locates exact timestamped moments in videos and hands off playback directly to the OS native video player.
* **Visual Similarity Search:** Match images based on visual features and feature vector similarity across local media collections.
* **Directory Scoping:** Full user control over which folders/directories QueryPic is permitted to scan and index.
* **Resource & Battery Protection:** Smart background scheduling that pauses heavy processing when thermal throttling occurs or battery drops below 20%.

---

## 📊 Feature Matrix & Tiering

| Feature | Free Tier | Pro Tier (Subscription) |
| :--- | :--- | :--- |
| **Local Indexing Limit** | Up to 10,000 files | Unlimited local files |
| **Visual Search** | Objects, Scenes, OCR Text | Objects, Scenes, OCR Text |
| **Video Search** | Thumbnail & object matching | Timed frame search + Speech-to-Text |
| **Advanced Tools** | Basic date filters | Visual Similarity + Fuzzy Temporal queries |

---

## 🛠 Tech Stack & Performance Targets

* **ML Models:** Quantized CoreML / TFLite / ONNX executed locally on standard CPU hardware (NPU not required).
* **Image Indexing Latency:** ~200–400 ms per photo (~1,000–1,500 photos/hour during background idle mode).
* **Video Frame Sampling:** 1 frame per 2–3 seconds of video footage.
* **Speech-to-Text:** ~1.0x–1.5x real-time CPU transcription speed.
* **Search Latency:** Sub-500 ms query execution time across an indexed library of 20,000 files.

---

## 📄 Documentation

* [Product Requirements Document (PRD)](./querypic_product_requirements_document.md)
* [Customer Journey Mapping](./CUSTOMER_JOURNEY.md)

---

## 🔒 Privacy & Data Architecture

QueryPic operates on a zero-knowledge principle:
1. **Local Sandboxing:** Vector embeddings, OCR indices, audio transcripts, and metadata are saved strictly inside the app's sandboxed local directory.
2. **Sanitized Telemetry:** Optional anonymous diagnostic/crash reporting strips file paths, queries, location data, and visual tokens prior to transmission.
