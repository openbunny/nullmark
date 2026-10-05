import Foundation

struct FileMetadata: Equatable {
  enum ReadError: LocalizedError {
    case nonUTF8AttributeName(Data)
    case embeddedNULPath

    var errorDescription: String? {
      switch self {
      case .nonUTF8AttributeName(let raw):
        let hex = raw.map { ($0 < 0x10 ? "0" : "") + String($0, radix: 16) }.joined()
        return """
          An extended attribute name is not valid UTF-8 (0x\(hex)). \
          It cannot be preserved, so the file was not opened.
          """

      case .embeddedNULPath:
        return
          "The file path contains a NUL character (U+0000), which C string interop truncates. Rename it and try again."
      }
    }
  }

  private static let keys: Set<URLResourceKey> = [
    .creationDateKey, .contentModificationDateKey, .contentAccessDateKey, .hasHiddenExtensionKey,
  ]
  private static let osAddedAttributes = ["com.apple.quarantine", "com.apple.provenance"]

  let created: Date?
  let modified: Date?
  let accessed: Date?
  let permissions: Int?
  // swiftlint:disable:next discouraged_optional_boolean - absence is distinct from a false flag
  let extensionHidden: Bool?
  let extendedAttributes: [String: Data]

  init(url: URL) throws {
    guard
      !url.path.utf8.contains(0),
      !url.path.contains("%00")
    else {
      throw ReadError.embeddedNULPath
    }
    let values = try url.resourceValues(forKeys: Self.keys)
    created = values.creationDate
    modified = values.contentModificationDate
    accessed = values.contentAccessDate
    extensionHidden = values.hasHiddenExtension
    permissions =
      try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    extendedAttributes = try Self.readExtendedAttributes(at: url)
  }

  private static func readExtendedAttributes(at url: URL) throws -> [String: Data] {
    let path = url.path
    let length = unsafe listxattr(path, nil, 0, XATTR_NOFOLLOW)
    guard length >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard length > 0 else {
      return [:]
    }
    var names = [CChar](repeating: 0, count: length)
    guard unsafe listxattr(path, &names, length, XATTR_NOFOLLOW) == length else {
      throw POSIXError(.EIO)
    }

    var result: [String: Data] = [:]
    for segment in names.split(separator: 0) {
      let bytes = segment.map { UInt8(bitPattern: $0) }
      guard let name = String(bytes: bytes, encoding: .utf8) else {
        throw ReadError.nonUTF8AttributeName(Data(bytes))
      }
      let size = unsafe getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
      guard size >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      var value = Data(count: size)
      let read = unsafe value.withUnsafeMutableBytes { bytes in
        unsafe getxattr(path, name, bytes.baseAddress, size, 0, XATTR_NOFOLLOW)
      }
      guard read == size else {
        throw POSIXError(.EIO)
      }
      result[name] = value
    }
    return result
  }

  func apply(to url: URL) throws -> [String] {
    var refused: [String] = []
    for (name, value) in extendedAttributes.sorted(by: { $0.key < $1.key }) {
      let status = unsafe value.withUnsafeBytes { bytes in
        unsafe setxattr(url.path, name, bytes.baseAddress, value.count, 0, XATTR_NOFOLLOW)
      }
      if status != 0 {
        refused.append("\(name) (\(unsafe String(cString: strerror(errno))))")
      }
    }
    if let permissions {
      try FileManager.default.setAttributes(
        [.posixPermissions: permissions], ofItemAtPath: url.path)
    }
    var values = URLResourceValues()
    values.creationDate = created
    values.contentModificationDate = modified
    values.contentAccessDate = accessed
    if let extensionHidden { values.hasHiddenExtension = extensionHidden }
    var target = url
    try target.setResourceValues(values)
    for name in Self.osAddedAttributes where extendedAttributes[name] == nil {
      _ = unsafe removexattr(url.path, name, XATTR_NOFOLLOW)
    }
    return refused
  }

  func differences(from other: Self) -> [String] {
    var result: [String] = []
    if created != other.created { result.append("creation date") }
    if modified != other.modified { result.append("modification date") }
    if permissions != other.permissions { result.append("permissions") }
    if extensionHidden != other.extensionHidden { result.append("hidden extension") }
    let expectedNames = Set(extendedAttributes.keys)
    let actualNames = Set(other.extendedAttributes.keys)
    let missing = expectedNames.subtracting(actualNames).map { "\($0) (missing)" }
    let added = actualNames.subtracting(expectedNames).map { "\($0) (added)" }
    let changed = expectedNames.intersection(actualNames)
      .filter { extendedAttributes[$0] != other.extendedAttributes[$0] }
      .map { "\($0) (changed)" }
    result.append(contentsOf: (missing + added + changed).sorted())
    return result
  }
}
