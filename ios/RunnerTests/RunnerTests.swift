import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testCumulativeUpdatesReplaceEarlierSamples() {
    var ledger = PedometerLedger()
    ledger.begin(sessionId: "study", at: 100)
    ledger.accept(steps: 10, distanceM: 7, end: 110)
    ledger.accept(steps: 14, distanceM: 9, end: 120)
    ledger.accept(steps: 14, distanceM: 9, end: 120)
    XCTAssertEqual(ledger.steps, 14)
    XCTAssertEqual(ledger.distanceM, 9)
    ledger.accept(steps: 11, distanceM: 8, end: 115)
    XCTAssertEqual(ledger.steps, 14)
  }

  func testPauseAndResumeExcludeThePausedInterval() {
    var ledger = PedometerLedger()
    ledger.begin(sessionId: "study", at: 100)
    ledger.running = false
    ledger.pendingEnd = 200
    ledger.accept(steps: 12, distanceM: 8, end: 200)
    ledger.finishInterval()
    ledger.begin(sessionId: "study", at: 500)
    ledger.accept(steps: 3, distanceM: 2, end: 600)
    XCTAssertEqual(ledger.steps, 15)
    XCTAssertEqual(ledger.distanceM, 10)
    XCTAssertEqual(ledger.anchor, 500)
  }

  func testPendingPauseSurvivesProcessRestartWithoutDoubleCounting() throws {
    var ledger = PedometerLedger()
    ledger.begin(sessionId: "study", at: 100)
    ledger.accept(steps: 10, distanceM: 7, end: 150)
    ledger.running = false
    ledger.pendingEnd = 200
    let saved = try JSONEncoder().encode(ledger)
    var restored = try JSONDecoder().decode(PedometerLedger.self, from: saved)
    XCTAssertEqual(restored.anchor, 100)
    XCTAssertEqual(restored.pendingEnd, 200)
    XCTAssertFalse(restored.running)
    restored.accept(steps: 13, distanceM: 9, end: 200)
    restored.finishInterval()
    XCTAssertEqual(restored.steps, 13)
    XCTAssertEqual(restored.distanceM, 9)
    XCTAssertNil(restored.anchor)
  }

  func testNoInventedDistanceAndOptionalCalibration() {
    var ledger = PedometerLedger()
    ledger.begin(sessionId: "study", at: 100)
    ledger.accept(steps: 10, distanceM: nil, end: 110)
    XCTAssertNil(ledger.stepLengthM)
    XCTAssertNil(ledger.distanceM)
    ledger.stepLengthM = 0.75
    XCTAssertEqual(ledger.distanceM, 7.5)
    ledger.stepLengthM = nil
    XCTAssertNil(ledger.distanceM)
  }

  func testHistoryOutsideSevenDaysPreservesKnownStepsAndFlagsGap() {
    let day: TimeInterval = 24 * 60 * 60
    var ledger = PedometerLedger()
    ledger.begin(sessionId: "study", at: 0)
    ledger.accept(steps: 10, distanceM: 7, end: 2 * day)
    ledger.prepareQuery(ending: 10 * day, now: 10 * day)
    XCTAssertEqual(ledger.anchor, 3 * day)
    XCTAssertEqual(ledger.steps, 10)
    XCTAssertTrue(ledger.gap)
    ledger.accept(steps: 4, distanceM: 3, end: 10 * day)
    XCTAssertEqual(ledger.steps, 14)
  }

  func testSavedRecentBoundaryAvoidsAFalseSevenDayGap() {
    let day: TimeInterval = 24 * 60 * 60
    var ledger = PedometerLedger()
    ledger.begin(sessionId: "study", at: 0)
    ledger.accept(steps: 10, distanceM: 7, end: 4 * day)
    ledger.prepareQuery(ending: 10 * day, now: 10 * day)
    XCTAssertEqual(ledger.anchor, 4 * day)
    XCTAssertEqual(ledger.steps, 10)
    XCTAssertFalse(ledger.gap)
  }

  func testExpiredPendingPauseNeverCollectsStepsAfterItsCutoff() {
    let day: TimeInterval = 24 * 60 * 60
    var ledger = PedometerLedger()
    ledger.begin(sessionId: "study", at: 0)
    ledger.accept(steps: 10, distanceM: 7, end: day)
    ledger.running = false
    ledger.pendingEnd = day
    ledger.prepareQuery(ending: day, now: 10 * day)
    XCTAssertNil(ledger.anchor)
    XCTAssertFalse(ledger.running)
    XCTAssertEqual(ledger.steps, 10)
    XCTAssertTrue(ledger.gap)
  }

  func testClockReversalKeepsThePauseCutoffAndFlagsCoverage() {
    var ledger = PedometerLedger()
    ledger.begin(sessionId: "study", at: 200)
    ledger.accept(steps: 10, distanceM: 7, end: 250)
    ledger.running = false
    ledger.pendingEnd = 100
    ledger.prepareQuery(ending: 100, now: 100)
    XCTAssertEqual(ledger.anchor, 100)
    XCTAssertEqual(ledger.pendingEnd, 100)
    XCTAssertEqual(ledger.steps, 10)
    XCTAssertTrue(ledger.gap)
  }

  func testInvalidSavedCountsCannotOverflowTheSnapshot() {
    var ledger = PedometerLedger()
    ledger.begin(sessionId: "study", at: 100)
    ledger.completedSteps = Int.max
    ledger.intervalSteps = 1
    XCTAssertFalse(ledger.isValid)
    ledger.completedSteps = 0
    ledger.intervalSteps = 0
    ledger.stepLengthM = -0.5
    XCTAssertFalse(ledger.isValid)
  }

}
