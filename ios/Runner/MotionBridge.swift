import CoreFoundation
import CoreMotion
import Flutter
import UIKit

/// Only aggregate values and one unfinished interval are retained. Core Motion
/// supplies the cumulative interval again after suspension or process restart.
struct PedometerLedger: Codable {
  var sessionId: String?
  var running = false
  var stepLengthM: Double?
  var completedSteps = 0
  var completedDistanceM: Double? = 0
  var anchor: TimeInterval?
  var pendingEnd: TimeInterval?
  var intervalSteps = 0
  var intervalDistanceM: Double?
  var observedAt: TimeInterval?
  var gap = false

  var steps: Int { completedSteps + intervalSteps }

  var isValid: Bool {
    guard completedSteps >= 0, intervalSteps >= 0,
          completedSteps <= Int.max - intervalSteps else { return false }
    let numbers = [stepLengthM, completedDistanceM, intervalDistanceM].compactMap { $0 }
    guard numbers.allSatisfy({ $0.isFinite && $0 >= 0 }),
          stepLengthM == nil || stepLengthM! > 0 else { return false }
    let dates = [anchor, pendingEnd, observedAt].compactMap { $0 }
    let maximumDate = Double(Int.max / 1000 - 1024)
    guard dates.allSatisfy({ $0.isFinite && abs($0) <= maximumDate }) else { return false }
    if running && (sessionId == nil || anchor == nil || pendingEnd != nil) { return false }
    if !running && anchor != nil && pendingEnd == nil { return false }
    if anchor == nil && (pendingEnd != nil || intervalSteps != 0 || intervalDistanceM != nil) { return false }
    if sessionId == nil && (completedSteps != 0 || anchor != nil || observedAt != nil || completedDistanceM != 0) { return false }
    return sessionId == nil || (!(sessionId?.isEmpty ?? true) && sessionId!.utf8.count <= 128)
  }

  var distanceM: Double? {
    guard sessionId != nil else { return nil }
    if let length = stepLengthM {
      let result = Double(steps) * length
      return result.isFinite ? result : nil
    }
    guard let completed = completedDistanceM else { return nil }
    if anchor == nil { return completed }
    guard let current = intervalDistanceM else { return nil }
    let sum = completed + current
    return sum.isFinite ? sum : nil
  }

  mutating func begin(sessionId id: String, at date: TimeInterval) {
    if sessionId != id {
      let length = stepLengthM
      self = PedometerLedger()
      stepLengthM = length
      sessionId = id
    }
    running = true
    anchor = date
    pendingEnd = nil
    intervalSteps = 0
    intervalDistanceM = nil
    observedAt = nil
  }

  /// Updates are cumulative from anchor, never increments to be added twice.
  mutating func accept(steps: Int, distanceM: Double?, end: TimeInterval) {
    guard anchor != nil else { return }
    guard end.isFinite, abs(end) <= Double(Int.max / 1000 - 1024) else {
      gap = true
      return
    }
    let safeSteps = min(max(0, steps), Int.max - completedSteps)
    if safeSteps != steps { gap = true }
    // A cumulative count can establish progress even when the wall clock moves
    // backwards. A lower count cannot replace a newer sample from this anchor.
    if safeSteps < intervalSteps { return }
    if safeSteps == intervalSteps, let previous = observedAt, end < previous { return }
    intervalSteps = safeSteps
    intervalDistanceM = distanceM.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    observedAt = end
  }

  mutating func finishInterval(missing: Bool = false) {
    guard anchor != nil else { return }
    completedSteps += intervalSteps
    if let completed = completedDistanceM, let current = intervalDistanceM {
      let sum = completed + current
      completedDistanceM = sum.isFinite ? sum : nil
    } else {
      completedDistanceM = nil
    }
    gap = gap || missing
    anchor = nil
    pendingEnd = nil
    intervalSteps = 0
    intervalDistanceM = nil
  }

  /// Rebase only at an already counted boundary, or flag an unrecoverable hole.
  /// Apple retains a maximum of seven days of pedometer history.
  mutating func prepareQuery(ending end: TimeInterval, now: TimeInterval) {
    guard let start = anchor else { return }
    let oldest = now - 7 * 24 * 60 * 60
    if start > end {
      let pauseEnd = pendingEnd
      finishInterval(missing: true)
      anchor = end
      pendingEnd = pauseEnd
      observedAt = nil
      return
    }
    if end < oldest {
      finishInterval(missing: true)
      return
    }
    guard start < oldest else { return }
    let knownEnd = observedAt ?? start
    let nextStart = min(end, max(knownEnd, oldest))
    let pauseEnd = pendingEnd
    finishInterval(missing: knownEnd < min(end, oldest))
    anchor = nextStart
    pendingEnd = pauseEnd
    observedAt = nil
  }
}

/// Ordering belongs to this native publisher, not to an adjustable wall clock.
/// It is deliberately not persisted with a study or its pedometer anchor.
struct MotionObservationOrder {
  static let maximumSequence: Int64 = 9_007_199_254_740_991
  private(set) var epoch: String
  private(set) var sequence: Int64

  init(epoch: String = UUID().uuidString, sequence: Int64 = 0) {
    self.epoch = epoch
    self.sequence = sequence
  }

  mutating func next() -> (epoch: String, sequence: Int64) {
    if sequence >= Self.maximumSequence {
      // Do not wrap within an epoch. A live Dart tracker fences this owner
      // change and requires reconnecting, rather than accepting stale order.
      epoch = UUID().uuidString
      sequence = 0
    }
    sequence += 1
    return (epoch, sequence)
  }
}

struct MotionCheckpointThrottle {
  private(set) var lastScheduledUptime: TimeInterval?

  func isDue(force: Bool, uptime: TimeInterval) -> Bool {
    guard !force, let previous = lastScheduledUptime else { return true }
    return uptime - previous >= 30
  }

  mutating func didSchedule(uptime: TimeInterval) {
    lastScheduledUptime = uptime
  }
}

/// No accelerometer polling, foreground service, animation or repeating timer.
/// All mutable state and Flutter callbacks are confined to the main queue.
final class MotionBridge: NSObject, FlutterStreamHandler {
  private let pedometer = CMPedometer()
  private static let storageKey = "field_tms.motion.v1"
  private let journal: MotionStateJournal?
  private let persistenceQueue = DispatchQueue(label: "field_tms.motion.storage", qos: .utility)
  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel
  private var ledger: PedometerLedger
  private var sink: FlutterEventSink?
  private var failureStatus: String?
  private var failureMessage: String?
  private var storageFailed = false
  private var needsRestore = true
  private var storageMessage: String?
  private var criticalWrites = 0
  private var generation = 0
  private var streaming = false
  private var operations: [(@escaping () -> Void) -> Void] = []
  private var busy = false
  private var checkpointThrottle = MotionCheckpointThrottle()
  private var observationOrder = MotionObservationOrder()
  private var foregroundObserver: NSObjectProtocol?
  private var backgroundObserver: NSObjectProtocol?

  init(messenger: FlutterBinaryMessenger, defaults: UserDefaults = .standard,
       stateJournal: MotionStateJournal? = nil) {
    journal = stateJournal ?? (try? MotionStateJournal.live(defaults: defaults, legacyKey: MotionBridge.storageKey))
    ledger = PedometerLedger()
    methods = FlutterMethodChannel(name: "field_tms/motion", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "field_tms/motion_events", binaryMessenger: messenger)
    super.init()
    // First in the operation queue: even migration and its flush run off the UI
    // thread, before any method can acknowledge a native transition.
    enqueue { done in self.restore { _ in done() } }
    methods.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    events.setStreamHandler(self)
    foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.enqueue { done in
        self?.refresh(requestPermission: false) { _ in done() }
      }
    }
    backgroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      self.enqueue { done in self.persist(force: true) { _ in done() } }
    }
  }

  deinit {
    pedometer.stopUpdates()
    if let observer = foregroundObserver { NotificationCenter.default.removeObserver(observer) }
    if let observer = backgroundObserver { NotificationCenter.default.removeObserver(observer) }
  }

  func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
    sink = eventSink
    enqueue { done in self.refresh(requestPermission: false) { _ in done() } }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    let requestedAt = Date().timeIntervalSince1970
    switch call.method {
    case "read":
      enqueue { done in
        self.refresh(requestPermission: false) { _ in result(self.snapshot()); done() }
      }
    case "start":
      guard let id = arguments["sessionId"] as? String, !id.isEmpty, id.utf8.count <= 128 else {
        result(invalid("A sessionId is required.")); return
      }
      guard validLength(arguments["stepLengthM"]) else {
        result(invalid("Step length must be a positive, finite number.")); return
      }
      enqueueReady(result: result) { done in
        if self.ledger.running && self.ledger.sessionId != id {
          result(FlutterError(code: "session_active", message: "Pause the current session first.", details: nil))
          done(); return
        }
        if arguments.keys.contains("stepLengthM") {
          self.ledger.stepLengthM = (arguments["stepLengthM"] as? NSNumber)?.doubleValue
        }
        if self.ledger.running {
          self.persist(force: true) { saved in
            guard saved else { result(self.snapshot()); done(); return }
            self.refresh(requestPermission: true) { _ in result(self.snapshot()); done() }
          }
          return
        }
        let begin = {
          if self.ledger.anchor != nil { self.ledger.finishInterval(missing: true) }
          let hadUnreadableState = self.ledger.sessionId == nil && self.ledger.gap
          self.ledger.begin(sessionId: id, at: requestedAt)
          self.ledger.gap = self.ledger.gap || hadUnreadableState
          self.failureStatus = nil
          self.failureMessage = nil
          self.persist(force: true) { saved in
            guard saved else { result(self.snapshot()); done(); return }
            self.refresh(requestPermission: true) { _ in result(self.snapshot()); done() }
          }
        }
        if self.ledger.anchor != nil {
          self.refresh(requestPermission: true) { _ in begin() }
        } else {
          begin()
        }
      }
    case "pause":
      guard let id = arguments["sessionId"] as? String, !id.isEmpty, id.utf8.count <= 128 else {
        result(invalid("A sessionId is required.")); return
      }
      enqueueReady(result: result) { done in
        guard self.ledger.sessionId == id else {
          result(FlutterError(code: "session_mismatch", message: "The motion session does not match.", details: nil))
          done(); return
        }
        self.stopUpdates()
        if self.ledger.running {
          self.ledger.running = false
          self.ledger.pendingEnd = requestedAt
          // If an earlier queued operation delayed this pause, cached values
          // after the requested cutoff cannot stand in for its final query.
          if (self.ledger.observedAt ?? 0) > requestedAt {
            self.ledger.intervalSteps = 0
            self.ledger.intervalDistanceM = nil
            self.ledger.observedAt = nil
          }
          // Persist the cutoff before querying, including if the app is killed.
          self.persist(force: true) { saved in
            guard saved else { result(self.snapshot()); done(); return }
            self.refresh(requestPermission: false) { _ in result(self.snapshot()); done() }
          }
          return
        }
        self.refresh(requestPermission: false) { _ in result(self.snapshot()); done() }
      }
    case "setStepLength":
      guard validLength(arguments["stepLengthM"]) else {
        result(invalid("Step length must be a positive, finite number.")); return
      }
      enqueueReady(result: result) { done in
        self.ledger.stepLengthM = (arguments["stepLengthM"] as? NSNumber)?.doubleValue
        self.persist(force: true) { saved in
          let reply = { self.emit(); result(self.snapshot()); done() }
          if saved && self.ledger.running && !self.streaming {
            self.refresh(requestPermission: false) { _ in reply() }
          } else {
            reply()
          }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func refresh(requestPermission: Bool, completion: @escaping (Bool) -> Void) {
    if needsRestore {
      restore { restored in
        guard restored else { self.emit(); completion(false); return }
        self.refresh(requestPermission: requestPermission, completion: completion)
      }
      return
    }
    if storageFailed {
      persist(force: true) { saved in
        guard saved else { self.emit(); completion(false); return }
        self.refresh(requestPermission: requestPermission, completion: completion)
      }
      return
    }
    guard ledger.sessionId != nil else { emit(); completion(true); return }
    guard CMPedometer.isStepCountingAvailable() else {
      unavailable("unavailable", "Step counting is unavailable on this device.")
      completion(false); return
    }
    switch CMPedometer.authorizationStatus() {
    case .denied, .restricted:
      unavailable("permissionDenied", "Allow Motion & Fitness access in Settings.")
      completion(false); return
    case .notDetermined where !requestPermission:
      unavailable("error", "Start timing to allow Motion & Fitness access.")
      completion(false); return
    default:
      break
    }
    guard ledger.anchor != nil else {
      failureStatus = nil
      failureMessage = nil
      emit(); completion(true); return
    }
    let now = Date().timeIntervalSince1970
    let end = ledger.pendingEnd ?? now
    let previousAnchor = ledger.anchor
    ledger.prepareQuery(ending: end, now: now)
    if ledger.anchor != previousAnchor {
      stopUpdates()
      persist(force: true) { saved in
        guard saved else { self.emit(); completion(false); return }
        self.refresh(requestPermission: requestPermission, completion: completion)
      }
      return
    }
    guard let anchor = ledger.anchor else {
      failureStatus = nil
      failureMessage = nil
      emit(); completion(true); return
    }
    let token = generation
    pedometer.queryPedometerData(from: Date(timeIntervalSince1970: anchor), to: Date(timeIntervalSince1970: end)) {
      [weak self] data, error in
      DispatchQueue.main.async {
        guard let self = self else { completion(false); return }
        guard self.generation == token && self.ledger.anchor == anchor else {
          completion(false); return
        }
        guard error == nil, let data = data else {
          self.motionFailed()
          completion(false); return
        }
        self.failureStatus = nil
        self.failureMessage = nil
        self.accept(data, anchor: anchor)
        let finishing = self.ledger.pendingEnd != nil
        if finishing { self.ledger.finishInterval() }
        self.persist(force: finishing) { saved in
          if saved && self.ledger.running { self.startUpdates() }
          self.emit()
          completion(saved)
        }
      }
    }
  }

  private func startUpdates() {
    guard !streaming, !storageFailed, !needsRestore,
          ledger.running, let anchor = ledger.anchor else { return }
    streaming = true
    let token = generation
    pedometer.startUpdates(from: Date(timeIntervalSince1970: anchor)) { [weak self] data, error in
      DispatchQueue.main.async {
        guard let self = self, self.generation == token,
              self.ledger.running, self.ledger.anchor == anchor else { return }
        guard error == nil, let data = data else { self.motionFailed(); return }
        self.failureStatus = nil
        self.failureMessage = nil
        self.accept(data, anchor: anchor)
        // The anchor is already durable. Throttle optional aggregate writes;
        // OS history restores every unsaved update without sensor polling.
        self.persist(force: false) { saved in
          if !saved { self.emit() }
        }
        self.emit()
      }
    }
  }

  private func accept(_ data: CMPedometerData, anchor: TimeInterval) {
    if data.startDate.timeIntervalSince1970 > anchor + 1 { ledger.gap = true }
    ledger.accept(
      steps: data.numberOfSteps.intValue,
      distanceM: data.distance?.doubleValue,
      end: data.endDate.timeIntervalSince1970
    )
  }

  private func stopUpdates() {
    generation += 1
    streaming = false
    pedometer.stopUpdates()
  }

  private func motionFailed() {
    let denied = CMPedometer.authorizationStatus() == .denied || CMPedometer.authorizationStatus() == .restricted
    unavailable(denied ? "permissionDenied" : "error", denied
      ? "Allow Motion & Fitness access in Settings."
      : "Motion data could not be read. Retry when the device is unlocked.")
  }

  private func unavailable(_ status: String, _ message: String) {
    stopUpdates()
    failureStatus = status
    failureMessage = message
    emit()
  }

  private func snapshot() -> [String: Any] {
    let order = observationOrder.next()
    let accessible = CMPedometer.isStepCountingAvailable() && CMPedometer.authorizationStatus() == .authorized
    let missing = ledger.gap || storageFailed || needsRestore || (ledger.anchor != nil && failureStatus != nil)
    let distance = accessible && failureStatus == nil && !missing ? ledger.distanceM : nil
    var message = storageMessage ?? failureMessage
    if message == nil && ledger.gap { message = "Some motion data is missing." }
    if message == nil && ledger.sessionId != nil && distance == nil {
      message = "Distance unavailable; set a calibrated step length."
    }
    return [
      "sessionId": ledger.sessionId as Any? ?? NSNull(),
      "status": storageFailed || needsRestore ? "error" : failureStatus ?? (ledger.sessionId == nil ? "idle" : ledger.running ? "running" : "paused"),
      "steps": ledger.steps,
      "distanceM": distance as Any? ?? NSNull(),
      "stepLengthM": ledger.stepLengthM as Any? ?? NSNull(),
      "source": accessible ? "ios_pedometer" : "unavailable",
      "estimated": true,
      "observedAtEpochMs": Int((ledger.observedAt ?? Date().timeIntervalSince1970) * 1000),
      "observationEpoch": order.epoch,
      "observationSequence": order.sequence,
      "gap": missing,
      "message": message as Any? ?? NSNull(),
    ]
  }

  private func emit() {
    // A concurrent cumulative sensor update must not publish a new session or
    // calibration while its critical checkpoint is still being committed.
    guard criticalWrites == 0 else { return }
    sink?(snapshot())
  }

  private func persist(force: Bool, completion: @escaping (Bool) -> Void = { _ in }) {
    let uptime = ProcessInfo.processInfo.systemUptime
    guard checkpointThrottle.isDue(force: force, uptime: uptime) else { completion(true); return }
    guard !needsRestore, let journal = journal else {
      storageFailure("Saved motion data could not be read. Retry after unlocking the device.")
      completion(false)
      return
    }
    let checkpoint = ledger
    // Throttle at scheduling time too; several native samples may arrive while
    // a slow flush is still pending. Critical transitions always bypass it.
    checkpointThrottle.didSchedule(uptime: uptime)
    if force { criticalWrites += 1 }
    persistenceQueue.async {
      let saved = Result { try journal.save(checkpoint) }
      DispatchQueue.main.async {
        if force { self.criticalWrites -= 1 }
        switch saved {
        case .success:
          self.storageFailed = false
          self.storageMessage = nil
          completion(true)
        case .failure:
          self.storageFailure("Motion state could not be saved. Walking coverage needs review.")
          completion(false)
        }
      }
    }
  }

  private func restore(completion: @escaping (Bool) -> Void) {
    guard let journal = journal else {
      storageFailure("Saved motion data could not be opened.")
      completion(false)
      return
    }
    persistenceQueue.async {
      let loaded = Result { try journal.load() }
      DispatchQueue.main.async {
        switch loaded {
        case .success(var saved):
          saved.gap = saved.gap || self.storageFailed
          self.ledger = saved
          self.needsRestore = false
          self.storageFailed = false
          self.storageMessage = nil
          self.checkpointThrottle.didSchedule(uptime: ProcessInfo.processInfo.systemUptime)
          completion(true)
        case .failure:
          // Keep an unreadable journal intact. In particular, do not overwrite
          // protected data with a fresh zero state before first unlock.
          self.storageFailure("Saved motion data could not be read. Retry after unlocking the device.")
          completion(false)
        }
      }
    }
  }

  private func storageFailure(_ message: String) {
    storageFailed = true
    storageMessage = message
    ledger.gap = true
    stopUpdates()
    emit()
  }

  private func enqueueReady(result: @escaping FlutterResult,
                            operation: @escaping (@escaping () -> Void) -> Void) {
    enqueue { done in
      guard self.needsRestore else { operation(done); return }
      self.restore { restored in
        if restored { operation(done) }
        else { result(self.snapshot()); done() }
      }
    }
  }

  private func enqueue(_ operation: @escaping (@escaping () -> Void) -> Void) {
    operations.append(operation)
    next()
  }

  private func next() {
    guard !busy, !operations.isEmpty else { return }
    busy = true
    let operation = operations.removeFirst()
    operation { [weak self] in
      guard let self = self else { return }
      self.busy = false
      self.next()
    }
  }

  private func validLength(_ value: Any?) -> Bool {
    guard let value = value, !(value is NSNull) else { return true }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
    return number.doubleValue.isFinite && number.doubleValue > 0
  }

  private func invalid(_ message: String) -> FlutterError {
    FlutterError(code: "invalid_arguments", message: message, details: nil)
  }
}
