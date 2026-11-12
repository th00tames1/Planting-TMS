import Foundation
import XCTest
@testable import Runner

/// These tests exercise the journal without requesting Motion & Fitness access.
/// They must still be compiled and executed with Xcode on macOS.
final class MotionBridgeTests: XCTestCase {
  func testRunningAnchorAndCalibrationRoundTrip() throws {
    let storage = MemoryMotionStorage()
    let journal = MotionStateJournal(storage: storage)
    var ledger = runningLedger()
    ledger.stepLengthM = 0.75
    try journal.save(ledger)
    let restored = try journal.load()
    XCTAssertEqual(restored.sessionId, "study")
    XCTAssertEqual(restored.anchor, 100)
    XCTAssertTrue(restored.running)
    XCTAssertEqual(restored.steps, 12)
    XCTAssertEqual(restored.distanceM, 9)
    XCTAssertEqual(storage.writes, 1)
    let document = try JSONSerialization.jsonObject(with: storage.data!) as! [String: Any]
    XCTAssertEqual(document["version"] as? Int, 1)
  }

  func testPendingPauseRecoveryUsesItsCommittedCutoffExactlyOnce() throws {
    let storage = MemoryMotionStorage()
    let journal = MotionStateJournal(storage: storage)
    var ledger = runningLedger()
    ledger.running = false
    ledger.pendingEnd = 200
    try journal.save(ledger)
    var restored = try journal.load()
    XCTAssertFalse(restored.running)
    XCTAssertEqual(restored.pendingEnd, 200)
    restored.accept(steps: 15, distanceM: 10, end: 200)
    restored.finishInterval()
    try journal.save(restored)
    restored = try journal.load()
    XCTAssertEqual(restored.steps, 15)
    XCTAssertEqual(restored.distanceM, 10)
    XCTAssertNil(restored.anchor)
    XCTAssertNil(restored.pendingEnd)
    restored.begin(sessionId: "study", at: 500)
    restored.accept(steps: 2, distanceM: 1, end: 510)
    XCTAssertEqual(restored.steps, 17)
  }

  func testLegacyMigrationCommitsBeforeRetiringDefaults() throws {
    let storage = MemoryMotionStorage()
    let legacy = try JSONEncoder().encode(runningLedger())
    var removed = false
    let journal = MotionStateJournal(
      storage: storage, legacyData: { legacy },
      removeLegacy: {
        XCTAssertNotNil(storage.data)
        removed = true
      }
    )
    let restored = try journal.load()
    XCTAssertEqual(restored.anchor, 100)
    XCTAssertEqual(restored.steps, 12)
    XCTAssertTrue(removed)
    XCTAssertEqual(storage.writes, 1)
    _ = try journal.load()
    XCTAssertEqual(storage.writes, 1, "A migrated journal must not migrate again.")
  }

  func testFailedMigrationRetainsLegacyAndDoesNotAcknowledgeCommit() throws {
    let storage = MemoryMotionStorage()
    storage.failWrites = true
    let legacy = try JSONEncoder().encode(runningLedger())
    var removed = false
    let journal = MotionStateJournal(
      storage: storage, legacyData: { legacy }, removeLegacy: { removed = true }
    )
    XCTAssertThrowsError(try journal.load())
    XCTAssertFalse(removed)
    XCTAssertNil(storage.data)
    storage.failWrites = false
    XCTAssertEqual(try journal.load().steps, 12)
    XCTAssertTrue(removed)
  }

  func testCorruptExistingJournalNeverFallsBackToLegacy() throws {
    let storage = MemoryMotionStorage()
    storage.data = Data("{\"version\":1,\"ledger\":".utf8)
    var legacyReads = 0
    let journal = MotionStateJournal(storage: storage, legacyData: {
      legacyReads += 1
      return try? JSONEncoder().encode(self.runningLedger())
    })
    let original = storage.data
    XCTAssertThrowsError(try journal.load())
    XCTAssertEqual(legacyReads, 0)
    XCTAssertEqual(storage.data, original)
    XCTAssertEqual(storage.writes, 0)
  }

  func testUnreadableExistingFileDoesNotFallBackOrOverwriteIt() {
    let storage = MemoryMotionStorage()
    storage.failReads = true
    var legacyReads = 0
    let journal = MotionStateJournal(storage: storage, legacyData: {
      legacyReads += 1
      return nil
    })
    XCTAssertThrowsError(try journal.load())
    XCTAssertEqual(legacyReads, 0)
    XCTAssertEqual(storage.writes, 0)
  }

  func testUnsupportedAndUnversionedJournalAreRejected() throws {
    let storage = MemoryMotionStorage()
    let journal = MotionStateJournal(storage: storage)
    try journal.save(runningLedger())
    var document = try JSONSerialization.jsonObject(with: storage.data!) as! [String: Any]
    for version in [0, 2] {
      document["version"] = version
      XCTAssertThrowsError(try MotionStateJournal.decode(JSONSerialization.data(withJSONObject: document)))
    }
    XCTAssertThrowsError(try MotionStateJournal.decode(JSONEncoder().encode(runningLedger())))
  }

  func testOversizedDocumentsAreRejectedBeforeLegacyOrDecode() {
    let storage = MemoryMotionStorage()
    storage.data = Data(repeating: 32, count: MotionStateJournal.maximumBytes + 1)
    XCTAssertThrowsError(try MotionStateJournal(storage: storage).load())
    storage.data = nil
    XCTAssertThrowsError(try MotionStateJournal(
      storage: storage,
      legacyData: { Data(repeating: 32, count: MotionStateJournal.maximumBytes + 1) }
    ).load())
    XCTAssertEqual(storage.writes, 0)
  }

  func testInvalidCountsAndNonfiniteOrInvalidCalibrationNeverCommit() {
    let storage = MemoryMotionStorage()
    let journal = MotionStateJournal(storage: storage)
    var ledger = runningLedger()
    ledger.intervalSteps = -1
    XCTAssertThrowsError(try journal.save(ledger))
    ledger = runningLedger()
    ledger.completedSteps = Int.max
    XCTAssertThrowsError(try journal.save(ledger))
    for length in [Double.nan, Double.infinity, -0.5, 0] {
      ledger = runningLedger()
      ledger.stepLengthM = length
      XCTAssertThrowsError(try journal.save(ledger))
    }
    ledger = runningLedger()
    ledger.anchor = .infinity
    XCTAssertThrowsError(try journal.save(ledger))
    ledger = runningLedger()
    ledger.sessionId = String(repeating: "x", count: 129)
    XCTAssertThrowsError(try journal.save(ledger))
    XCTAssertEqual(storage.writes, 0)
  }

  func testFailedReplacementLeavesTheLastSafeAnchorAvailable() throws {
    let storage = MemoryMotionStorage()
    let journal = MotionStateJournal(storage: storage)
    let ledger = runningLedger()
    try journal.save(ledger)
    let committed = storage.data
    var pending = ledger
    pending.running = false
    pending.pendingEnd = 200
    storage.failWrites = true
    XCTAssertThrowsError(try journal.save(pending))
    XCTAssertEqual(storage.data, committed)
    XCTAssertTrue(try journal.load().running)
    storage.failWrites = false
    try journal.save(pending)
    XCTAssertFalse(try journal.load().running)
    XCTAssertEqual(try journal.load().pendingEnd, 200)
  }

  func testDecodedInvalidNumbersAndInconsistentPhaseAreRejected() throws {
    let storage = MemoryMotionStorage()
    let journal = MotionStateJournal(storage: storage)
    try journal.save(runningLedger())
    let valid = try JSONSerialization.jsonObject(with: storage.data!) as! [String: Any]
    for change in [
      ["intervalSteps": -1] as [String: Any],
      ["completedSteps": Int.max],
      ["stepLengthM": "NaN"],
      ["running": false], // An unfinished paused interval needs its cutoff.
    ] {
      var document = valid
      var ledger = document["ledger"] as! [String: Any]
      for (key, value) in change { ledger[key] = value }
      document["ledger"] = ledger
      XCTAssertThrowsError(try MotionStateJournal.decode(JSONSerialization.data(withJSONObject: document)))
    }
  }

  func testInvalidLegacyDocumentIsNotRemovedOrReplaced() {
    let storage = MemoryMotionStorage()
    var removed = false
    let journal = MotionStateJournal(
      storage: storage,
      legacyData: { Data("{\"completedSteps\":-1}".utf8) },
      removeLegacy: { removed = true }
    )
    XCTAssertThrowsError(try journal.load())
    XCTAssertFalse(removed)
    XCTAssertEqual(storage.writes, 0)
  }

  func testFreshInstallationHasNoInventedDistanceAndDoesNotWrite() throws {
    let storage = MemoryMotionStorage()
    let restored = try MotionStateJournal(storage: storage).load()
    XCTAssertNil(restored.sessionId)
    XCTAssertNil(restored.distanceM)
    XCTAssertEqual(restored.steps, 0)
    XCTAssertFalse(restored.gap)
    XCTAssertEqual(storage.writes, 0)
  }

  func testAtomicFileReplacementIgnoresUncommittedTemporaryFiles() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("motion-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("motion-state-v1.json")
    let journal = MotionStateJournal(storage: AtomicMotionStateFile(url: file))
    XCTAssertNil(try AtomicMotionStateFile(url: file).read())
    var ledger = runningLedger()
    try journal.save(ledger)
    try Data("partial uncommitted replacement".utf8).write(
      to: directory.appendingPathComponent("motion-orphan.tmp")
    )
    XCTAssertEqual(try journal.load().steps, 12)
    ledger.running = false
    ledger.pendingEnd = 200
    try journal.save(ledger)
    XCTAssertEqual(try journal.load().pendingEnd, 200)
    let temporary = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasSuffix(".tmp") }
    XCTAssertEqual(temporary, ["motion-orphan.tmp"])
  }

  func testFirstInstallWithAbsentParentDirectoriesLoadsAnEmptyLedger() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("motion-first-install-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Library/Application Support/FieldMotion", isDirectory: true)
      .appendingPathComponent("motion-state-v1.json")
    let storage = AtomicMotionStateFile(url: file)
    XCTAssertNil(try storage.read())
    let ledger = try MotionStateJournal(storage: storage).load()
    XCTAssertNil(ledger.sessionId)
    XCTAssertFalse(ledger.running)
    XCTAssertFalse(ledger.gap)
    XCTAssertNil(ledger.distanceM)
  }

  func testMissingJournalInsideAnExistingEmptyDirectoryIsNotAnError() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("motion-empty-parent-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let storage = AtomicMotionStateFile(url: directory.appendingPathComponent("motion-state-v1.json"))
    XCTAssertNil(try storage.read())
    XCTAssertNil(try MotionStateJournal(storage: storage).load().sessionId)
  }

  func testLegacyOnlyDefaultsMigrateThroughTheRealFileManagerWithAbsentParents() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("motion-real-migration-\(UUID().uuidString)", isDirectory: true)
    let suite = "motion-migration-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    let key = "field_tms.motion.v1"
    defaults.set(try JSONEncoder().encode(runningLedger()), forKey: key)
    let file = directory.appendingPathComponent("Application Support/FieldMotion", isDirectory: true)
      .appendingPathComponent("motion-state-v1.json")
    let storage = AtomicMotionStateFile(url: file)
    XCTAssertNil(try storage.read())
    let journal = MotionStateJournal(
      storage: storage,
      legacyData: { defaults.data(forKey: key) },
      removeLegacy: { defaults.removeObject(forKey: key) }
    )
    XCTAssertEqual(try journal.load().anchor, 100)
    XCTAssertEqual(try journal.load().steps, 12)
    XCTAssertNil(defaults.data(forKey: key))
    let committed = try MotionStateJournal.decode(Data(contentsOf: file))
    XCTAssertEqual(committed.sessionId, "study")
    XCTAssertTrue(committed.running)
  }

  func testOnlyTheTwoCocoaMissingFileCodesAreTreatedAsAbsent() throws {
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("motion-error-test-\(UUID().uuidString).json")
    for code in [NSFileNoSuchFileError, NSFileReadNoSuchFileError] {
      let manager = AttributesErrorFileManager(error: NSError(domain: NSCocoaErrorDomain, code: code))
      XCTAssertNil(try AtomicMotionStateFile(url: file, fileManager: manager).read())
    }
    for error in [
      NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
      NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError),
      NSError(domain: NSPOSIXErrorDomain, code: NSFileNoSuchFileError),
    ] {
      let manager = AttributesErrorFileManager(error: error)
      XCTAssertThrowsError(try AtomicMotionStateFile(url: file, fileManager: manager).read())
    }
  }

  func testHigherCumulativeStepsSurviveABackwardWallClock() {
    var ledger = PedometerLedger()
    ledger.begin(sessionId: "study", at: 100)
    ledger.accept(steps: 10, distanceM: 7, end: 200)
    ledger.accept(steps: 12, distanceM: 8.5, end: 150)
    XCTAssertEqual(ledger.steps, 12)
    XCTAssertEqual(ledger.distanceM, 8.5)
    XCTAssertEqual(ledger.observedAt, 150, "Keep the real sample timestamp.")
    XCTAssertFalse(ledger.gap)
    XCTAssertTrue(ledger.isValid)
  }

  func testLowerCountCallbackCannotOverwriteProgressWithALaterWallDate() {
    var ledger = PedometerLedger()
    ledger.begin(sessionId: "study", at: 100)
    ledger.accept(steps: 10, distanceM: 7, end: 200)
    ledger.accept(steps: 12, distanceM: 8.5, end: 150)
    ledger.accept(steps: 10, distanceM: 7, end: 200)
    ledger.accept(steps: 11, distanceM: 8, end: 250)
    XCTAssertEqual(ledger.steps, 12)
    XCTAssertEqual(ledger.distanceM, 8.5)
    XCTAssertEqual(ledger.observedAt, 150)
  }

  func testEqualCountRefinementAcceptsNewerSamplesAndRejectsOlderOnes() {
    var ledger = PedometerLedger()
    ledger.begin(sessionId: "study", at: 100)
    ledger.accept(steps: 12, distanceM: 8.5, end: 150)
    ledger.accept(steps: 12, distanceM: 8.25, end: 160)
    XCTAssertEqual(ledger.distanceM, 8.25)
    ledger.accept(steps: 12, distanceM: 7, end: 140)
    XCTAssertEqual(ledger.distanceM, 8.25)
    XCTAssertEqual(ledger.observedAt, 160)
  }

  func testBackwardDatedProgressRoundTripsWithoutPersistingPublisherOrder() throws {
    let storage = MemoryMotionStorage()
    let journal = MotionStateJournal(storage: storage)
    var ledger = PedometerLedger()
    ledger.begin(sessionId: "study", at: 100)
    ledger.accept(steps: 10, distanceM: 7, end: 200)
    try journal.save(ledger)
    ledger = try journal.load()
    ledger.accept(steps: 12, distanceM: 8.5, end: 150)
    try journal.save(ledger)
    ledger = try journal.load()
    XCTAssertEqual(ledger.steps, 12)
    XCTAssertEqual(ledger.observedAt, 150)
    let document = try JSONSerialization.jsonObject(with: storage.data!) as! [String: Any]
    let savedLedger = document["ledger"] as! [String: Any]
    XCTAssertNil(savedLedger["observationEpoch"])
    XCTAssertNil(savedLedger["observationSequence"])
  }

  func testSnapshotOrderHasOneEpochAndIncrementsForEveryCapture() {
    var order = MotionObservationOrder()
    let first = order.next()
    let second = order.next()
    let third = order.next()
    XCTAssertNotNil(UUID(uuidString: first.epoch))
    XCTAssertEqual(first.sequence, 1)
    XCTAssertEqual(second.sequence, 2)
    XCTAssertEqual(third.sequence, 3)
    XCTAssertEqual(first.epoch, second.epoch)
    XCTAssertEqual(first.epoch, third.epoch)
    var replacementOwner = MotionObservationOrder()
    let replacement = replacementOwner.next()
    XCTAssertNotEqual(first.epoch, replacement.epoch)
    XCTAssertEqual(replacement.sequence, 1)
  }

  func testSnapshotSequenceExhaustionChangesEpochInsteadOfWrappingWithinIt() {
    var order = MotionObservationOrder(
      epoch: "previous-owner", sequence: MotionObservationOrder.maximumSequence - 1
    )
    let last = order.next()
    XCTAssertEqual(last.sequence, 9_007_199_254_740_991)
    XCTAssertEqual(last.epoch, "previous-owner")
    let renewed = order.next()
    XCTAssertEqual(renewed.sequence, 1)
    XCTAssertNotEqual(renewed.epoch, last.epoch)
    XCTAssertNotNil(UUID(uuidString: renewed.epoch))
  }

  func testCheckpointThrottleUsesElapsedUptimeAndAlwaysAllowsCriticalWrites() {
    var throttle = MotionCheckpointThrottle()
    XCTAssertTrue(throttle.isDue(force: false, uptime: 100))
    throttle.didSchedule(uptime: 100)
    XCTAssertFalse(throttle.isDue(force: false, uptime: 100.001))
    XCTAssertFalse(throttle.isDue(force: false, uptime: 129.999))
    XCTAssertTrue(throttle.isDue(force: false, uptime: 130))
    throttle.didSchedule(uptime: 130)
    XCTAssertFalse(throttle.isDue(force: false, uptime: 130))
    XCTAssertTrue(throttle.isDue(force: true, uptime: 130))
    throttle.didSchedule(uptime: 130)
    XCTAssertTrue(throttle.isDue(force: false, uptime: 160))
  }

  private func runningLedger() -> PedometerLedger {
    var ledger = PedometerLedger()
    ledger.begin(sessionId: "study", at: 100)
    ledger.accept(steps: 12, distanceM: 8, end: 150)
    return ledger
  }
}

private final class MemoryMotionStorage: MotionStateStorage {
  var data: Data?
  var writes = 0
  var failReads = false
  var failWrites = false
  func read() throws -> Data? {
    if failReads { throw CocoaError(.fileReadNoPermission) }
    return data
  }
  func write(_ data: Data) throws {
    if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
    self.data = data
    writes += 1
  }
}

private final class AttributesErrorFileManager: FileManager {
  let error: NSError
  init(error: NSError) {
    self.error = error
    super.init()
  }
  override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
    throw error
  }
}
