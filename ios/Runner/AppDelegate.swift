import Flutter
import UIKit
import CoreLocation
import Darwin
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var motionBridge: MotionBridge?
  private var exportBridge: ExportBridge?
  private var locationBridge: FieldLocationBridge?
  private var delayAudioBridge: DelayAudioBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = registrar(forPlugin: "FieldPreferences") {
      FlutterMethodChannel(name: "field_tms/preferences", binaryMessenger: registrar.messenger()).setMethodCallHandler { call, reply in
        switch call.method {
        case "readDark": reply(UserDefaults.standard.object(forKey: "field_dark"))
        case "writeDark":
          let args = call.arguments as? [String: Any] ?? [:]
          UserDefaults.standard.set(args["dark"] as? Bool ?? false, forKey: "field_dark"); reply(nil)
        default: reply(FlutterMethodNotImplemented)
        }
      }
    }
    if let registrar = registrar(forPlugin: "FieldDelayAudioBridge") {
      delayAudioBridge = DelayAudioBridge(messenger: registrar.messenger())
    }
    if let registrar = registrar(forPlugin: "FieldLocationBridge") {
      locationBridge = FieldLocationBridge(messenger: registrar.messenger())
    }
    if let registrar = registrar(forPlugin: "FieldExportBridge") {
      exportBridge = ExportBridge(messenger: registrar.messenger()) { [weak self] in
        self?.window?.rootViewController
      }
    }
    if let registrar = registrar(forPlugin: "FieldMotionBridge") {
      motionBridge = MotionBridge(messenger: registrar.messenger())
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

/// Compressed mono audio is encoded directly into one private file per Delay.
final class DelayAudioBridge: NSObject, AVAudioRecorderDelegate, FlutterStreamHandler {
  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel
  private var sink: FlutterEventSink?
  private var recorder: AVAudioRecorder?
  private var player: AVAudioPlayer?
  private var current: String?
  private var started: String?
  private var wanted: String?
  private var pending: FlutterResult?
  private var pendingFile: String?
  private let formatter = ISO8601DateFormatter()
  private var directory: URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return root.appendingPathComponent("delay-notes", isDirectory: true)
  }
  private func valid(_ file: String) -> Bool { file.range(of: "^note-study-[0-9]+-[0-9]+-[0-9]+\\.m4a$", options: .regularExpression) != nil }
  init(messenger: FlutterBinaryMessenger) {
    methods = FlutterMethodChannel(name: "field_tms/delay_audio", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "field_tms/delay_audio_events", binaryMessenger: messenger)
    super.init()
    events.setStreamHandler(self)
    NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: AVAudioSession.interruptionNotification, object: nil)
    methods.setMethodCallHandler { [weak self] call, reply in
      guard let self = self else { reply(nil); return }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "setTarget":
        let file = args["file"] as? String
        if let file = file, !self.valid(file) { reply(FlutterError(code: "file", message: "Invalid audio note.", details: nil)); return }
        self.pending?(["file": self.pendingFile ?? "", "status": "cancelled"])
        self.pending = nil; self.pendingFile = nil; self.wanted = file
        self.player?.stop(); self.player = nil
        if file == self.current, self.recorder?.isRecording == true {
          reply(["file": file!, "status": "recording", "startedUtc": self.started ?? ""]); return
        }
        let ended = self.finish()
        guard let file = file else { reply(ended ?? ["status": "off"]); return }
        self.pending = reply; self.pendingFile = file
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
          DispatchQueue.main.async {
            guard let self = self, self.wanted == file, self.pendingFile == file, let result = self.pending else { return }
            self.pending = nil; self.pendingFile = nil
            result(granted ? self.begin(file) : ["file": file, "status": "denied"])
          }
        }
      case "deleteStudy":
        guard let id = args["studyId"] as? String, id.range(of: "^study-[0-9]+-[0-9]+$", options: .regularExpression) != nil, self.recorder == nil else {
          reply(FlutterError(code: "study", message: "Stop recording before Reset.", details: nil)); return
        }
        do {
          self.player?.stop(); self.player = nil
          if FileManager.default.fileExists(atPath: self.directory.path) {
            for url in try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil) where self.valid(url.lastPathComponent) && url.lastPathComponent.hasPrefix("note-\(id)-") {
              try FileManager.default.removeItem(at: url)
            }
          }
          reply(nil)
        } catch { reply(FlutterError(code: "delete", message: "Some audio notes could not be deleted.", details: nil)) }
      case "play":
        guard let file = args["file"] as? String, self.valid(file), self.recorder == nil else { reply(FlutterError(code: "audio", message: "Stop recording before playing a note.", details: nil)); return }
        do {
          let session = AVAudioSession.sharedInstance()
          try session.setCategory(.playback); try session.setActive(true)
          self.player?.stop()
          self.player = try AVAudioPlayer(contentsOf: self.directory.appendingPathComponent(file))
          guard self.player?.play() == true else { throw NSError(domain: "audio", code: 1) }
          reply(nil)
        } catch { reply(FlutterError(code: "audio", message: "This audio note is unavailable.", details: nil)) }
      case "stopPlayback":
        self.player?.stop(); self.player = nil
        if self.recorder == nil { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        reply(nil)
      default: reply(FlutterMethodNotImplemented)
      }
    }
  }
  private func begin(_ file: String) -> [String: Any] {
    let url = directory.appendingPathComponent(file)
    if FileManager.default.fileExists(atPath: url.path) { return ["file": file, "status": "interrupted"] }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
      try session.setActive(true)
      let candidate = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000.0, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000])
      candidate.delegate = self
      guard candidate.prepareToRecord(), candidate.record() else { throw NSError(domain: "audio", code: 2) }
      recorder = candidate; current = file; started = formatter.string(from: Date())
      return ["file": file, "status": "recording", "startedUtc": started!]
    } catch {
      try? FileManager.default.removeItem(at: url)
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      return ["file": file, "status": "error"]
    }
  }
  private func finish(status: String = "saved") -> [String: Any]? {
    guard let recording = recorder, let file = current else { return nil }
    let duration = recording.currentTime
    recording.stop(); recorder = nil; current = nil
    var status = status
    if duration < 0.1 { status = "too_short"; try? FileManager.default.removeItem(at: directory.appendingPathComponent(file)) }
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    return ["file": file, "status": status, "startedUtc": started ?? "", "endedUtc": formatter.string(from: Date())]
  }
  @objc private func interrupted(_ notification: Notification) {
    guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, type == AVAudioSession.InterruptionType.began.rawValue else { return }
    if let result = finish(status: "interrupted") { sink?(result) }
  }
  func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) { if let result = finish(status: "error") { sink?(result) } }
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { sink = events; return nil }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }
  deinit { NotificationCenter.default.removeObserver(self); _ = finish(status: "interrupted") }
}

/// Kept in this compiled source so every Runner configuration includes it.
final class FieldLocationBridge: NSObject, FlutterStreamHandler, CLLocationManagerDelegate {
  private let manager = CLLocationManager()
  private var sink: FlutterEventSink?
  private var latest: [String: Any] = ["status": "off"]
  private let publisher = UUID().uuidString
  private var serial: Int64 = 0
  private var wanted = false
  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel
  private var authorization: CLAuthorizationStatus {
    if #available(iOS 14.0, *) { return manager.authorizationStatus }
    return CLLocationManager.authorizationStatus()
  }

  init(messenger: FlutterBinaryMessenger) {
    methods = FlutterMethodChannel(name: "field_tms/location", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "field_tms/location_events", binaryMessenger: messenger)
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    manager.distanceFilter = kCLDistanceFilterNone
    manager.activityType = .other
    manager.pausesLocationUpdatesAutomatically = true
    latest = ["status": "off", "publisher": publisher, "serial": serial]
    events.setStreamHandler(self)
    methods.setMethodCallHandler { [weak self] call, reply in
      guard let self = self else { reply(FlutterError(code: "closed", message: "Location closed", details: nil)); return }
      switch call.method {
      case "clockInfo":
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        let result = sysctlbyname("kern.boottime", &boot, &size, nil, 0)
        guard result == 0 else { reply(FlutterError(code: "clock", message: "Boot identity unavailable", details: nil)); return }
        reply(["bootId": "ios-\(boot.tv_sec)-\(boot.tv_usec)"])
      case "enable":
        self.wanted = true
        if self.authorization == .notDetermined { self.manager.requestWhenInUseAuthorization() }
        self.beginIfAuthorized()
        reply(self.latest)
      case "start": self.wanted = true; self.beginIfAuthorized(); reply(self.latest)
      case "stop":
        self.wanted = false
        self.manager.stopUpdatingLocation()
        self.manager.allowsBackgroundLocationUpdates = false
        self.publish(["status": "off"])
        reply(self.latest)
      default: reply(FlutterMethodNotImplemented)
      }
    }
  }
  private func publish(_ value: [String: Any]) {
    serial += 1
    latest = value.merging(["publisher": publisher, "serial": serial]) { _, new in new }
    sink?(latest)
  }
  private func beginIfAuthorized() {
    guard wanted else { return }
    switch authorization {
    case .authorizedAlways, .authorizedWhenInUse:
      manager.allowsBackgroundLocationUpdates = true
      manager.showsBackgroundLocationIndicator = true
      manager.startUpdatingLocation()
      if latest["latitude"] == nil { publish(["status": "waiting"]) }
    case .denied, .restricted: publish(["status": "denied"])
    default: publish(["status": "permission_required"])
    }
  }
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { beginIfAuthorized() }
  func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) { beginIfAuthorized() }
  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard wanted, let fix = locations.last, fix.horizontalAccuracy >= 0 else { return }
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS else { publish(["status": "error"]); return }
    let mono = Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    let age = Date().timeIntervalSince(fix.timestamp) * 1000
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var simulated = false
    if #available(iOS 15.0, *) { simulated = fix.sourceInformation?.isSimulatedBySoftware ?? false }
    publish(["status": age < 0 ? "clock_mismatch" : "fresh", "latitude": fix.coordinate.latitude,
      "longitude": fix.coordinate.longitude, "accuracyM": fix.horizontalAccuracy,
      "fixUtc": formatter.string(from: fix.timestamp), "fixMonoMs": Int64(mono - age), "mock": simulated])
  }
  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    publish(["status": (error as? CLError)?.code == .denied ? "denied" : "unavailable"])
  }
  func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) { publish(["status": "paused"])
  }
  func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
    sink = eventSink; eventSink(latest); return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }
}
