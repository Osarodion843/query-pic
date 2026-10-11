import AVFoundation
import Flutter
import UIKit

/// Phase 6 device vitals plugin (battery / thermal / free disk).
/// Registered on the implicit engine bridge below. NOTE: needs a Mac
/// `flutter build ios` to compile-check (Windows hosts can't verify Swift).
class VitalsPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "querypic/vitals",
      binaryMessenger: registrar.messenger(),
    )
    let instance = VitalsPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "getVitals" else {
      result(FlutterMethodNotImplemented)
      return
    }
    result(Self.readVitals())
  }

  static func readVitals() -> [String: Any?] {
    UIDevice.current.isBatteryMonitoringEnabled = true
    let level = UIDevice.current.batteryLevel // -1.0 when unknown
    let batteryPct: Double? = level >= 0 ? Double(level) * 100.0 : nil
    let state = UIDevice.current.batteryState
    let charging = state == .charging || state == .full

    let thermal: Int
    switch ProcessInfo.processInfo.thermalState {
    case .nominal:
      thermal = 0
    case .fair:
      thermal = 1
    case .serious:
      thermal = 2
    case .critical:
      thermal = 3
    @unknown default:
      thermal = 0
    }

    var freeDiskBytes: Int64?
    if let attrs = try? FileManager.default.attributesOfFileSystem(
      forPath: NSHomeDirectory(),
    ) {
      freeDiskBytes = (attrs[.systemFreeSize] as? NSNumber)?.int64Value
    }

    return [
      "batteryPct": batteryPct,
      "charging": charging,
      "thermal": thermal,
      "freeDiskBytes": freeDiskBytes,
    ]
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "VitalsPlugin",
    ) {
      VitalsPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "AudioPlugin",
    ) {
      AudioPlugin.register(with: registrar)
    }
  }
}

/// Phase 5 STT debug path (see MainActivity.kt): decode [durSec] of audio
/// to 16 kHz mono float32. NOTE: needs a Mac `flutter build ios` to
/// compile-check (Windows hosts can't verify Swift).
class AudioPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "querypic/audio",
      binaryMessenger: registrar.messenger(),
    )
    let instance = AudioPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "extractPcm",
      let args = call.arguments as? [String: Any],
      let path = args["path"] as? String
    else {
      result(FlutterMethodNotImplemented)
      return
    }
    let startSec = (args["startSec"] as? Double) ?? 0
    let durSec = (args["durSec"] as? Double) ?? 30
    DispatchQueue.global().async {
      do {
        let raw = try Self.extractPcmRaw(
          path: path,
          startSec: startSec,
          durSec: durSec,
        )
        DispatchQueue.main.async {
          result([
            "sampleRate": raw.sampleRate,
            "channels": raw.channels,
            "encoding": 2,
            "pcm": raw.pcm,
            // Native extractor build fingerprint (see MainActivity.kt).
            "ext": 4,
          ] as [String: Any])
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "AUDIO_DECODE",
            message: "\(error)",
            details: nil,
          ))
        }
      }
    }
  }

  /// Raw decoder bytes with format metadata. Decoding, downmixing and
  /// resampling happen in tested Dart code; this side only demuxes.
  static func extractPcmRaw(
    path: String,
    startSec: Double,
    durSec: Double,
  ) throws -> (sampleRate: Int, channels: Int, pcm: Data) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = asset.tracks(withMediaType: .audio).first else {
      throw NSError(domain: "AudioPlugin", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "no audio track"])
    }
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(
      start: CMTime(seconds: startSec, preferredTimescale: 600),
      duration: CMTime(seconds: durSec, preferredTimescale: 600),
    )
    // Request the decoder's native PCM (int16 stereo typical); Dart
    // interprets per the encoding flag it reports alongside.
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let output = AVAssetReaderTrackOutput(track: track,
                                          outputSettings: settings)
    reader.add(output)
    reader.startReading()
    var pcm = Data()
    var sampleRate = 44100
    var channels = 2
    while reader.status == .reading {
      guard let sample = output.copyNextSampleBuffer() else { break }
      guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
      if let fmt = CMSampleBufferGetFormatDescription(sample),
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) {
        sampleRate = Int(asbd.pointee.mSampleRate)
        channels = Int(asbd.pointee.mChannelsPerFrame)
      }
      var length = 0
      var bytes: UnsafeMutablePointer<Int8>?
      CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                  totalLengthOut: &length, dataPointerOut: &bytes)
      if let bytes = bytes, length > 0 {
        pcm.append(bytes, count: length)
      }
    }
    guard reader.status == .completed else {
      throw NSError(domain: "AudioPlugin", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "reader failed"])
    }
    return (sampleRate, channels, pcm)
  }
}
