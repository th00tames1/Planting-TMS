import Darwin
import Foundation

enum MotionJournalError: Error {
  case tooLarge
  case invalidState
  case unsupportedVersion
  case fileOperation(Int32)
}

protocol MotionStateStorage {
  func read() throws -> Data?
  func write(_ data: Data) throws
}

/// A small aggregate checkpoint, never a sensor sample log. Calls are serialized
/// on MotionBridge's utility queue so a storage flush cannot block the UI.
final class MotionStateJournal {
  static let maximumBytes = 16 * 1024
  private struct Envelope: Codable {
    let version: Int
    let ledger: PedometerLedger
  }

  private let storage: MotionStateStorage
  private let legacyData: () -> Data?
  private let removeLegacy: () -> Void

  init(storage: MotionStateStorage, legacyData: @escaping () -> Data? = { nil },
       removeLegacy: @escaping () -> Void = {}) {
    self.storage = storage
    self.legacyData = legacyData
    self.removeLegacy = removeLegacy
  }

  static func live(defaults: UserDefaults, legacyKey: String) throws -> MotionStateJournal {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: false
    )
    let file = support.appendingPathComponent("FieldMotion", isDirectory: true)
      .appendingPathComponent("motion-state-v1.json")
    return MotionStateJournal(
      storage: AtomicMotionStateFile(url: file),
      legacyData: { defaults.data(forKey: legacyKey) },
      removeLegacy: { defaults.removeObject(forKey: legacyKey) }
    )
  }

  func load() throws -> PedometerLedger {
    // An existing but invalid journal must never revive an older running anchor
    // from defaults. An orphan temporary file is never a committed checkpoint.
    if let data = try storage.read() { return try Self.decode(data) }
    guard let legacy = legacyData() else { return PedometerLedger() }
    guard legacy.count <= Self.maximumBytes else { throw MotionJournalError.tooLarge }
    let ledger = try JSONDecoder().decode(PedometerLedger.self, from: legacy)
    guard ledger.isValid else { throw MotionJournalError.invalidState }
    try save(ledger)
    removeLegacy() // Only retire the old state after the new checkpoint commits.
    return ledger
  }

  func save(_ ledger: PedometerLedger) throws {
    guard ledger.isValid else { throw MotionJournalError.invalidState }
    let data = try JSONEncoder().encode(Envelope(version: 1, ledger: ledger))
    guard data.count <= Self.maximumBytes else { throw MotionJournalError.tooLarge }
    try storage.write(data)
  }

  static func decode(_ data: Data) throws -> PedometerLedger {
    guard data.count <= maximumBytes else { throw MotionJournalError.tooLarge }
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard envelope.version == 1 else { throw MotionJournalError.unsupportedVersion }
    guard envelope.ledger.isValid else { throw MotionJournalError.invalidState }
    return envelope.ledger
  }
}

/// Write and flush a same-directory temporary file, atomically replace the
/// checkpoint, then flush directory metadata. A killed process sees the old or
/// new complete document. This is not a claim of hardware power-loss immunity.
final class AtomicMotionStateFile: MotionStateStorage {
  let url: URL
  private let fileManager: FileManager

  init(url: URL, fileManager: FileManager = .default) {
    self.url = url
    self.fileManager = fileManager
  }

  func read() throws -> Data? {
    do {
      let attributes = try fileManager.attributesOfItem(atPath: url.path)
      if let size = attributes[.size] as? NSNumber,
         size.uint64Value > UInt64(MotionStateJournal.maximumBytes) {
        throw MotionJournalError.tooLarge
      }
      return try Data(contentsOf: url)
    } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
      (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
      return nil
    }
  }

  func write(_ data: Data) throws {
    guard data.count <= MotionStateJournal.maximumBytes else { throw MotionJournalError.tooLarge }
    var directory = url.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    )
    var resources = URLResourceValues()
    resources.isExcludedFromBackup = true // Native history belongs to this device.
    try directory.setResourceValues(resources)
    let temporary = directory.appendingPathComponent("motion-\(UUID().uuidString).tmp")
    defer { try? fileManager.removeItem(at: temporary) }
    try data.write(to: temporary, options: .completeFileProtectionUntilFirstUserAuthentication)
    let handle = try FileHandle(forWritingTo: temporary)
    do {
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
    let renamed = temporary.withUnsafeFileSystemRepresentation { from in
      url.withUnsafeFileSystemRepresentation { to in Darwin.rename(from!, to!) }
    }
    guard renamed == 0 else { throw MotionJournalError.fileOperation(errno) }
    let descriptor = Darwin.open(directory.path, O_RDONLY)
    guard descriptor >= 0 else { throw MotionJournalError.fileOperation(errno) }
    defer { Darwin.close(descriptor) }
    var flushed: Int32
    repeat { flushed = Darwin.fsync(descriptor) } while flushed == -1 && errno == EINTR
    guard flushed == 0 else { throw MotionJournalError.fileOperation(errno) }
  }
}
