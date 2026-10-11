package com.example.querypic

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaRecorder
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private val channelName = "querypic/vitals"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName,
        ).setMethodCallHandler { call, result ->
            if (call.method == "getVitals") {
                result.success(readVitals())
            } else {
                result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "querypic/open",
        ).setMethodCallHandler { call, result ->
            if (call.method == "openFile") {
                val path = call.argument<String>("path")
                val isVideo = call.argument<Boolean>("isVideo") ?: false
                if (path == null) {
                    result.error("OPEN_ARGS", "missing path", null)
                    return@setMethodCallHandler
                }
                try {
                    openFileInGallery(path, isVideo)
                    result.success(true)
                } catch (e: android.content.ActivityNotFoundException) {
                    result.error("NO_APP", "no app can open this file", null)
                } catch (e: SecurityException) {
                    // Read grant rejected: retry via the MediaStore row URI,
                    // which the system gallery owns outright.
                    try {
                        openViaMediaStore(path, isVideo)
                        result.success(true)
                    } catch (e2: android.content.ActivityNotFoundException) {
                        result.error("NO_APP", "no app can open this file", null)
                    } catch (e2: Exception) {
                        result.error(
                            "OPEN_FAILED",
                            shortCause(e2),
                            e2.toString(),
                        )
                    }
                } catch (e: IllegalArgumentException) {
                    // FileProvider can't cover this path (secondary volume):
                    // same MediaStore fallback.
                    try {
                        openViaMediaStore(path, isVideo)
                        result.success(true)
                    } catch (e2: android.content.ActivityNotFoundException) {
                        result.error("NO_APP", "no app can open this file", null)
                    } catch (e2: Exception) {
                        result.error(
                            "OPEN_FAILED",
                            shortCause(e2),
                            e2.toString(),
                        )
                    }
                } catch (e: Exception) {
                    result.error(
                        "OPEN_FAILED",
                        shortCause(e),
                        e.toString(),
                    )
                }
            } else {
                result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "querypic/mic",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startRecording" -> {
                    try {
                        val path = micStart()
                        result.success(path)
                    } catch (e: SecurityException) {
                        result.error("NO_PERMISSION", "mic permission denied", null)
                    } catch (e: Exception) {
                        result.error("MIC_FAILED", shortCause(e), e.toString())
                    }
                }
                "stopRecording" -> {
                    try {
                        val path = micStop()
                        if (path == null) {
                            result.error("NOT_RECORDING", "nothing recording", null)
                        } else {
                            result.success(path)
                        }
                    } catch (e: Exception) {
                        result.error("MIC_FAILED", shortCause(e), e.toString())
                    }
                }
                "cancelRecording" -> {
                    micCancel()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "querypic/audio",
        ).setMethodCallHandler { call, result ->            if (call.method == "extractPcm") {
                val path = call.argument<String>("path")
                val startSec = (call.argument<Double>("startSec") ?: 0.0)
                val durSec = (call.argument<Double>("durSec") ?: 30.0)
                if (path == null) {
                    result.error("AUDIO_ARGS", "missing path", null)
                    return@setMethodCallHandler
                }
                // Decode off the UI thread; reply back on it.
                thread {
                    try {
                        val out = extractPcmRaw(path, startSec, durSec)
                        runOnUiThread {
                            result.success(out)
                        }
                    } catch (e: Exception) {
                        runOnUiThread {
                            result.error(
                                "AUDIO_DECODE",
                                e.message ?: e.toString(),
                                null,
                            )
                        }
                    }
                }
            } else {
                result.notImplemented()
            }
        }
    }

    /// Gallery handoff: open [path] in the system viewer via FileProvider.
    /// file:// intents throw FileUriExposedException on API 24+; the
    /// content:// URI plus a one-shot read grant opens in Photos/Gallery.
    private fun openFileInGallery(path: String, isVideo: Boolean = false) {
        val file = File(path)
        require(file.exists()) { "file not found" }
        val uri: Uri = FileProvider.getUriForFile(
            this,
            "${applicationContext.packageName}.fileprovider",
            file,
        )
        fireView(uri, mimeFor(path))
    }

    private fun fireView(uri: Uri, mime: String) {
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        // The grant must also sit on the chooser itself, or some gallery
        // apps receive the URI without read rights and refuse it.
        val chooser = Intent.createChooser(intent, "Open with")
        chooser.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(chooser)
    }

    /// Fallback for paths FileProvider can't serve (SD cards) or grants the
    /// viewer rejects: resolve the MediaStore row for [path] and open its
    /// system-owned content:// URI instead.
    private fun openViaMediaStore(path: String, isVideo: Boolean) {
        val uri = mediaStoreUriForPath(path, isVideo)
            ?: throw IllegalStateException("not in media library")
        fireView(uri, if (isVideo) "video/*" else mimeFor(path))
    }

    private fun mediaStoreUriForPath(path: String, isVideo: Boolean): Uri? {
        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            if (isVideo) {
                android.provider.MediaStore.Video.Media.getContentUri(
                    android.provider.MediaStore.VOLUME_EXTERNAL,
                )
            } else {
                android.provider.MediaStore.Images.Media.getContentUri(
                    android.provider.MediaStore.VOLUME_EXTERNAL,
                )
            }
        } else {
            if (isVideo) {
                android.provider.MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            } else {
                android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            }
        }
        val cursor = contentResolver.query(
            collection,
            arrayOf(android.provider.MediaStore.MediaColumns._ID),
            "${android.provider.MediaStore.MediaColumns.DATA}=?",
            arrayOf(path),
            null,
        ) ?: return null
        cursor.use {
            if (!it.moveToFirst()) return null
            val id = it.getLong(0)
            return android.content.ContentUris.withAppendedId(collection, id)
        }
    }

    /// One-line cause for the Flutter snackbar (full text rides in details
    /// for logcat). Never leaks the absolute path.
    private fun shortCause(e: Exception): String {
        val raw = e.message ?: e.javaClass.simpleName
        val first = raw.lineSequence().firstOrNull()?.trim() ?: "open failed"
        return first.take(120)
    }

    // ---- Push-to-talk voice search (querypic/mic) ----
    // AudioRecord 16 kHz mono int16 straight to a WAV in the app cache:
    // exactly what the Whisper frontend wants, no decode step. The file is
    // the caller's to delete (the Dart side removes it after transcription).
    // 15 s cap keeps utterances query-sized and RAM bounded.
    private var micRecorder: AudioRecord? = null
    private var micThread: Thread? = null
    private var micFile: File? = null
    private var micStopFlag = false

    @Synchronized
    private fun micStart(): String {
        micCancel()
        val rate = 16000
        val minBuf = AudioRecord.getMinBufferSize(
            rate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        require(minBuf > 0) { "mic unavailable on this device" }
        val rec = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            rate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            minBuf * 2,
        )
        require(rec.state == AudioRecord.STATE_INITIALIZED) {
            "mic init failed"
        }
        val file = File(cacheDir, "qp_voice_${System.currentTimeMillis()}.wav")
        // WAV header with placeholder sizes; patched on stop.
        FileOutputStream(file).use { it.write(wavHeader(rate, 0)) }
        micRecorder = rec
        micFile = file
        micStopFlag = false
        rec.startRecording()
        micThread = thread {
            val out = try {
                FileOutputStream(file, true)
            } catch (e: Exception) {
                null
            }
            val buf = ByteArray(minBuf)
            // 15 s * 16 kHz * 2 bytes, plus a small margin.
            var remaining = 15 * 16000 * 2 + 4096
            while (!micStopFlag && remaining > 0) {
                val n = try {
                    rec.read(buf, 0, minOf(buf.size, remaining))
                } catch (e: Exception) {
                    -1
                }
                if (n == null || n <= 0) break
                try {
                    out?.write(buf, 0, n)
                } catch (e: Exception) {
                    break
                }
                remaining -= n
            }
            try {
                out?.close()
            } catch (e: Exception) {
            }
            patchWavSizes(file)
        }
        return file.absolutePath
    }

    @Synchronized
    private fun micStop(): String? {
        micStopFlag = true
        try {
            micThread?.join(2000)
        } catch (e: Exception) {
        }
        try {
            micRecorder?.stop()
        } catch (e: Exception) {
        }
        try {
            micRecorder?.release()
        } catch (e: Exception) {
        }
        micRecorder = null
        micThread = null
        val f = micFile
        micFile = null
        return f?.absolutePath
    }

    @Synchronized
    private fun micCancel() {
        micStopFlag = true
        try {
            micThread?.join(1000)
        } catch (e: Exception) {
        }
        try {
            micRecorder?.stop()
        } catch (e: Exception) {
        }
        try {
            micRecorder?.release()
        } catch (e: Exception) {
        }
        micRecorder = null
        micThread = null
        try {
            micFile?.delete()
        } catch (e: Exception) {
        }
        micFile = null
    }

    private fun wavHeader(rate: Int, dataBytes: Int): ByteArray {
        val total = 36 + dataBytes
        val buf = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        buf.put("RIFF".toByteArray())
        buf.putInt(total)
        buf.put("WAVE".toByteArray())
        buf.put("fmt ".toByteArray())
        buf.putInt(16)
        buf.putShort(1) // PCM
        buf.putShort(1) // mono
        buf.putInt(rate)
        buf.putInt(rate * 2) // byte rate
        buf.putShort(2) // block align
        buf.putShort(16) // bits
        buf.put("data".toByteArray())
        buf.putInt(dataBytes)
        return buf.array()
    }

    private fun patchWavSizes(file: File) {
        try {
            val len = file.length()
            if (len < 44) return
            val dataBytes = (len - 44).toInt()
            val raf = java.io.RandomAccessFile(file, "rw")
            try {
                raf.seek(4)
                val sizes = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
                sizes.putInt(36 + dataBytes)
                sizes.putInt(dataBytes)
                raf.write(sizes.array(), 0, 4)
                raf.seek(40)
                raf.write(sizes.array(), 4, 4)
            } finally {
                raf.close()
            }
        } catch (e: Exception) {
        }
    }

    private fun mimeFor(path: String): String {
        val ext = MimeTypeMap.getFileExtensionFromUrl(Uri.fromFile(File(path)).toString())
            ?.lowercase()
        val mime = if (ext != null) {
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
        } else {
            null
        }
        if (mime != null) return mime
        // Extension unknown: sniff by common photo/video suffixes.
        val lower = path.lowercase()
        return when {
            lower.endsWith(".mp4") || lower.endsWith(".mkv") ||
                lower.endsWith(".webm") || lower.endsWith(".3gp") ||
                lower.endsWith(".mov") -> "video/*"
            else -> "image/*"
        }
    }

    /// Phase 6 device vitals (battery / thermal / free disk).
    /// Battery via the sticky ACTION_BATTERY_CHANGED intent (all API
    /// levels); thermal via PowerManager on API 29+, else 0 (unknown);
    /// free space via filesDir.usableSpace.
    private fun readVitals(): Map<String, Any?> {
        val battery: Intent? = registerReceiver(
            null,
            IntentFilter(Intent.ACTION_BATTERY_CHANGED),
        )
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val batteryPct = if (level >= 0 && scale > 0) {
            level * 100.0 / scale
        } else {
            null
        }
        val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL

        var thermal = 0
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            thermal = when (pm.currentThermalStatus) {
                PowerManager.THERMAL_STATUS_NONE -> 0
                PowerManager.THERMAL_STATUS_LIGHT -> 1
                PowerManager.THERMAL_STATUS_MODERATE -> 2
                else -> 3 // SEVERE, CRITICAL, EMERGENCY, SHUTDOWN
            }
        }

        val freeDiskBytes = try {
            filesDir.usableSpace
        } catch (e: Exception) {
            null
        }

        return mapOf(
            "batteryPct" to batteryPct,
            "charging" to charging,
            "thermal" to thermal,
            "freeDiskBytes" to freeDiskBytes,
        )
    }

    /// Phase 5 STT debug path: decode [durSec] of audio from [path],
    /// returning RAW decoder bytes with their format metadata. Decoding,
    /// downmixing and resampling all happen in tested Dart code
    /// (services/resample.dart) — this side only demuxes + decodes.
    /// Chunked by the caller (30 s windows). Throws on missing file,
    /// audio-less containers, or codec failure.
    private fun extractPcmRaw(
        path: String,
        startSec: Double,
        durSec: Double,
    ): Map<String, Any?> {
        val extractor = MediaExtractor()
        extractor.setDataSource(path)
        try {
            var track = -1
            var srcRate = 0
            var channels = 0
            var mime = ""
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val m = f.getString(MediaFormat.KEY_MIME) ?: ""
                if (m.startsWith("audio/")) {
                    track = i
                    mime = m
                    srcRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    break
                }
            }
            if (track < 0) throw IllegalArgumentException("no audio track")
            extractor.selectTrack(track)
            // WAV/PCM tracks need no decoder: the extractor itself is
            // the demuxer — copy sample bytes directly. (Dart-side file
            // reads hit scoped-storage EACCES where this path works.)
            if (mime == "audio/raw") {
                val encoding = try {
                    extractor.getTrackFormat(track).let {
                        if (it.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                            it.getInteger(MediaFormat.KEY_PCM_ENCODING)
                        } else {
                            2
                        }
                    }
                } catch (e: Exception) {
                    2
                }
                return extractRawSamples(
                    extractor, startSec, durSec, srcRate, channels, encoding,
                )
            }
            extractor.seekTo(
                (startSec * 1e6).toLong(),
                MediaExtractor.SEEK_TO_CLOSEST_SYNC,
            )
            val decoder = MediaCodec.createDecoderByType(mime)
            decoder.configure(extractor.getTrackFormat(track), null, null, 0)
            decoder.start()
            try {
                val startUs = (startSec * 1e6).toLong()
                val endUs = ((startSec + durSec) * 1e6).toLong()
                val chunks = mutableListOf<ByteArray>()
                var totalBytes = 0
                // Generous cap: 32 s at 48 kHz stereo float32.
                val maxBytes = ((durSec + 2.0) * 48000 * 2 * 4).toInt()
                var sawInputEos = false
                var idleRounds = 0
                var sawOutputEos = false
                val info = MediaCodec.BufferInfo()
                while (totalBytes < maxBytes &&
                    idleRounds < 500 &&
                    !sawOutputEos
                ) {
                    if (!sawInputEos) {
                        val inIdx = decoder.dequeueInputBuffer(10_000)
                        if (inIdx >= 0) {
                            val buf = decoder.getInputBuffer(inIdx)!!
                            val n = extractor.readSampleData(buf, 0)
                            if (n < 0) {
                                decoder.queueInputBuffer(
                                    inIdx, 0, 0, 0,
                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                                )
                                sawInputEos = true
                            } else {
                                decoder.queueInputBuffer(
                                    inIdx, 0, n,
                                    extractor.sampleTime, 0,
                                )
                                extractor.advance()
                            }
                        }
                    }
                    val outIdx = decoder.dequeueOutputBuffer(info, 10_000)
                    when {
                        outIdx >= 0 -> {
                            idleRounds = 0
                            if (info.size > 0 &&
                                info.presentationTimeUs >= startUs &&
                                (info.flags and
                                    MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0
                            ) {
                                val buf = decoder.getOutputBuffer(outIdx)!!
                                buf.position(info.offset)
                                buf.limit(info.offset + info.size)
                                val raw = ByteArray(info.size)
                                buf.get(raw)
                                chunks.add(raw)
                                totalBytes += info.size
                            }
                            decoder.releaseOutputBuffer(outIdx, false)
                            if ((info.flags and
                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                            ) {
                                sawOutputEos = true
                            }
                            if (info.presentationTimeUs >= endUs) break
                        }
                        outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> idleRounds++
                        else -> idleRounds = 0 // format change: keep going
                    }
                }
                val encoding = try {
                    val of = decoder.outputFormat
                    if (of.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                        of.getInteger(MediaFormat.KEY_PCM_ENCODING)
                    } else {
                        2 // ENCODING_PCM_16BIT
                    }
                } catch (e: Exception) {
                    2
                }
                val pcm = ByteArray(totalBytes)
                var pos = 0
                for (c in chunks) {
                    c.copyInto(pcm, pos)
                    pos += c.size
                }
                return mapOf(
                    "sampleRate" to srcRate,
                    "channels" to channels,
                    "encoding" to encoding,
                    "pcm" to pcm,
                    // Native extractor build fingerprint: bump on every
                    // extractor change so the device dialog proves which
                    // code ran.
                    "ext" to 5,
                )
            } finally {
                decoder.stop()
                decoder.release()
            }
        } finally {
            extractor.release()
        }
    }

    /// Raw PCM tracks (WAV): no decoder exists for audio/raw, so copy
    /// the sample bytes directly within [startSec, startSec + durSec).
    /// Format comes from the track itself (our debug WAV is 16 kHz mono
    /// int16); anything missing falls back to those defaults.
    private fun extractRawSamples(
        extractor: MediaExtractor,
        startSec: Double,
        durSec: Double,
        srcRate: Int,
        channels: Int,
        encoding: Int,
    ): Map<String, Any?> {
        extractor.seekTo(
            (startSec * 1e6).toLong(),
            MediaExtractor.SEEK_TO_CLOSEST_SYNC,
        )
        val startUs = (startSec * 1e6).toLong()
        val endUs = ((startSec + durSec) * 1e6).toLong()
        val chunks = mutableListOf<ByteArray>()
        var totalBytes = 0
        val maxBytes = ((durSec + 2.0) * 48000 * 2 * 4).toInt()
        val tmp = ByteBuffer.allocate(65536)
        while (totalBytes < maxBytes) {
            tmp.clear()
            val n = extractor.readSampleData(tmp, 0)
            if (n < 0) break
            val pts = extractor.sampleTime
            extractor.advance()
            if (pts < startUs) continue
            if (pts >= endUs) break
            val b = ByteArray(n)
            tmp.get(b)
            chunks.add(b)
            totalBytes += n
        }
        val pcm = ByteArray(totalBytes)
        var pos = 0
        for (c in chunks) {
            c.copyInto(pcm, pos)
            pos += c.size
        }
        return mapOf(
            "sampleRate" to srcRate,
            "channels" to channels,
            "encoding" to encoding,
            "pcm" to pcm,
            "ext" to 5,
        )
    }
}
