import Flutter
import UIKit

/// App-owned buffers contain at most one 64 KiB chunk. Files receives a URL,
/// rather than the workbook bytes; the system provider performs the final copy.
final class ExportBridge: NSObject, UIDocumentPickerDelegate {
  private let channel: FlutterMethodChannel
  private let presenter: () -> UIViewController?
  private let io = DispatchQueue(label: "field_tms.export", qos: .userInitiated)
  private let root: URL
  // State below is owned by the serial IO queue.
  private var spool: Spool?
  private var pickerReply: FlutterResult?
  // Main-thread picker identity is separate from queue-owned spool state.
  private var presentedPicker: UIDocumentPickerViewController?
  private var presentedToken: String?
  private let chunkSize = 64 * 1024
  private let maxBytes: Int64 = 512 * 1024 * 1024
  private let reserveBytes: Int64 = 64 * 1024 * 1024

  private final class Spool {
    let token: String
    let file: URL
    let output: OutputStream
    var bytes: Int64 = 0
    var closed = false
    init(token: String, file: URL, output: OutputStream) {
      self.token = token; self.file = file; self.output = output
    }
    func close() { if !closed { output.close(); closed = true } }
    func delete() { close(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
  }
  private enum ExportFailure: Error, Equatable { case invalid, space, io }

  init(messenger: FlutterBinaryMessenger, presenter: @escaping () -> UIViewController?) {
    channel = FlutterMethodChannel(name: "field_tms/export", binaryMessenger: messenger)
    self.presenter = presenter
    root = FileManager.default.temporaryDirectory.appendingPathComponent("field_exports", isDirectory: true)
    super.init()
    io.async { [self] in
      // A killed export has no retained external references on the next launch.
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    channel.setMethodCallHandler { [weak self] call, reply in
      guard let self = self else {
        reply(FlutterError(code: "export_unavailable", message: "File export is unavailable.", details: nil)); return
      }
      self.io.async { self.handle(call, reply: reply) }
    }
  }

  private func handle(_ call: FlutterMethodCall, reply: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    do {
      switch call.method {
      case "begin":
        guard spool == nil else { failure(reply, code: "export_busy"); return }
        let created = try create(args)
        spool = created
        success(reply, ["token": created.token])
      case "append":
        guard let current = matching(args) else { failure(reply, code: "export_invalid"); return }
        guard !current.closed else { failure(reply, code: "export_busy"); return }
        guard let typed = args?["bytes"] as? FlutterStandardTypedData,
              typed.data.count <= chunkSize else {
          throw ExportFailure.invalid
        }
        try append(current, data: typed.data)
        success(reply, nil)
      case "finish":
        guard let current = matching(args), !current.closed, pickerReply == nil else {
          failure(reply, code: "export_invalid"); return
        }
        current.close()
        pickerReply = reply
        DispatchQueue.main.async { [weak self] in self?.present(current.file, token: current.token) }
      case "abort":
        if let current = matching(args) {
          let waiting = pickerReply; pickerReply = nil
          current.delete(); spool = nil
          DispatchQueue.main.async { [weak self] in
            guard let self = self, self.presentedToken == current.token else { return }
            self.presentedPicker?.delegate = nil
            self.presentedPicker?.dismiss(animated: true)
            self.presentedPicker = nil; self.presentedToken = nil
          }
          if let waiting = waiting { success(waiting, ["status": "cancelled"]) }
        }
        success(reply, nil)
      // Compatibility for callers of the original save API. The UI streams.
      case "save":
        guard spool == nil else { failure(reply, code: "export_busy"); return }
        guard let typed = args?["bytes"] as? FlutterStandardTypedData,
              typed.data.count <= 32 * 1024 * 1024 else { throw ExportFailure.invalid }
        let created = try create(args)
        spool = created
        var offset = 0
        while offset < typed.data.count {
          let end = min(offset + chunkSize, typed.data.count)
          try append(created, data: typed.data.subdata(in: offset..<end))
          offset = end
        }
        created.close(); pickerReply = reply
        DispatchQueue.main.async { [weak self] in self?.present(created.file, token: created.token) }
      default:
        DispatchQueue.main.async { reply(FlutterMethodNotImplemented) }
      }
    } catch {
      spool?.delete(); spool = nil
      failure(reply, code: (error as? ExportFailure) == .space ? "export_space" : "export_failed")
    }
  }

  private func create(_ args: [String: Any]?) throws -> Spool {
    guard let name = args?["fileName"] as? String, !name.isEmpty, name.count <= 128,
          name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
          let mime = args?["mimeType"] as? String,
          ["text/csv", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"].contains(mime) else {
      throw ExportFailure.invalid
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try checkSpace(additional: chunkSize)
    let token = UUID().uuidString
    let directory = root.appendingPathComponent(token, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let file = directory.appendingPathComponent(name)
    guard let output = OutputStream(url: file, append: false) else {
      try? FileManager.default.removeItem(at: directory); throw ExportFailure.io
    }
    output.open()
    guard output.streamStatus == .open else {
      output.close(); try? FileManager.default.removeItem(at: directory); throw ExportFailure.io
    }
    return Spool(token: token, file: file, output: output)
  }

  private func matching(_ args: [String: Any]?) -> Spool? {
    guard let current = spool, let token = args?["token"] as? String,
          current.token == token else { return nil }
    return current
  }

  private func checkSpace(additional: Int) throws {
    let attributes = try FileManager.default.attributesOfFileSystem(forPath: root.path)
    guard let available = (attributes[.systemFreeSize] as? NSNumber)?.int64Value,
          available >= reserveBytes + Int64(additional) else { throw ExportFailure.space }
  }

  private func append(_ current: Spool, data: Data) throws {
    guard current.bytes + Int64(data.count) <= maxBytes else { throw ExportFailure.invalid }
    try checkSpace(additional: data.count)
    try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
      var offset = 0
      while offset < data.count {
        let written = current.output.write(base.advanced(by: offset), maxLength: data.count - offset)
        if written <= 0 { throw ExportFailure.io }
        offset += written
      }
    }
    current.bytes += Int64(data.count)
  }

  private func present(_ file: URL, token: String) {
    guard UIApplication.shared.applicationState == .active,
          var viewController = presenter() else { finish(token: token, status: nil); return }
    while let presented = viewController.presentedViewController { viewController = presented }
    guard viewController.viewIfLoaded?.window != nil else { finish(token: token, status: nil); return }
    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) { picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true) }
    else { picker = UIDocumentPickerViewController(url: file, in: .exportToService) }
    picker.delegate = self
    presentedPicker = picker; presentedToken = token
    viewController.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    pickerFinished(controller, status: urls.isEmpty ? nil : "saved")
  }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { pickerFinished(controller, status: "cancelled") }

  private func pickerFinished(_ picker: UIDocumentPickerViewController, status: String?) {
    guard picker === presentedPicker, let token = presentedToken else { return }
    presentedPicker = nil; presentedToken = nil
    finish(token: token, status: status)
  }

  private func finish(token: String, status: String?) {
    io.async { [self] in
      // Ignore a late callback from a picker cancelled before a newer begin.
      guard spool?.token == token else { return }
      let reply = pickerReply; pickerReply = nil
      spool?.delete(); spool = nil
      guard let reply = reply else { return }
      if let status = status { success(reply, ["status": status]) }
      else { failure(reply, code: "export_failed") }
    }
  }
  private func success(_ reply: @escaping FlutterResult, _ value: Any?) {
    DispatchQueue.main.async { reply(value) }
  }
  private func failure(_ reply: @escaping FlutterResult, code: String) {
    DispatchQueue.main.async {
      reply(FlutterError(code: code, message: code == "export_space"
        ? "Not enough free space to prepare this export."
        : "Could not save the file. Try again.", details: nil))
    }
  }
}
