import Foundation
import PDFKit

struct PDFMetadata {
  struct Entry: Identifiable {
    let key: String
    let display: String

    var id: String { key }
  }

  private static let headerProbeLength = 16
  private static let versionLength = 3

  let info: [Entry]
  let version: String
  let fileID: String?
  let xmp: Data?

  init(document: PDFDocument, data: Data) {
    version = Self.headerVersion(data)
    info = Self.infoEntries(document.documentAttributes ?? [:])
    fileID = Self.trailerFileID(data)
    xmp = Self.xmpPacket(data)
  }

  private static func headerVersion(_ data: Data) -> String {
    guard let header = String(bytes: data.prefix(headerProbeLength), encoding: .ascii),
      let marker = header.range(of: "%PDF-")
    else {
      return "Unknown"
    }
    return String(header[marker.upperBound...].prefix(versionLength))
  }

  private static func infoEntries(_ attributes: [AnyHashable: Any]) -> [Entry] {
    let known: [(PDFDocumentAttribute, String)] = [
      (.titleAttribute, "Title"), (.authorAttribute, "Author"),
      (.subjectAttribute, "Subject"), (.keywordsAttribute, "Keywords"),
      (.creatorAttribute, "Creator"), (.producerAttribute, "Producer"),
      (.creationDateAttribute, "Created"), (.modificationDateAttribute, "Modified"),
    ]
    return known.compactMap { attribute, label in
      guard let value = attributes[attribute] else {
        return nil
      }
      return Entry(key: label, display: describe(value))
    }
  }

  private static func describe(_ value: Any) -> String {
    if let date = value as? Date {
      return date.formatted(date: .abbreviated, time: .standard)
    }
    if let list = value as? [Any] {
      return list.map { "\($0)" }.joined(separator: ", ")
    }
    return "\(value)"
  }

  private static func trailerFileID(_ data: Data) -> String? {
    guard let marker = data.range(of: Data("/ID".utf8), options: .backwards) else {
      return nil
    }
    guard
      let open = data.range(of: Data("<".utf8), in: marker.upperBound..<data.endIndex),
      let close = data.range(of: Data(">".utf8), in: open.upperBound..<data.endIndex)
    else {
      return nil
    }
    return String(bytes: data[open.upperBound..<close.lowerBound], encoding: .ascii)
  }

  private static func xmpPacket(_ data: Data) -> Data? {
    guard let start = data.range(of: Data("<?xpacket begin".utf8)) else {
      return nil
    }
    guard
      let endMarker = data.range(
        of: Data("<?xpacket end".utf8), in: start.upperBound..<data.endIndex),
      let close = data.range(of: Data("?>".utf8), in: endMarker.upperBound..<data.endIndex)
    else {
      return nil
    }
    return data.subdata(in: start.lowerBound..<close.upperBound)
  }
}
