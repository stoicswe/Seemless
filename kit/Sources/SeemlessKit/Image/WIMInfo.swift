import Foundation

/// Reads the image catalogue of a Windows imaging file (`install.wim` or
/// `install.esd`) without Microsoft tools (docs/03 stage 2 "Inspect").
///
/// Only the fixed 208-byte header and the XML data resource are read, so a
/// multi-gigabyte image costs a few hundred kilobytes of I/O.
public struct WIMInfo: Sendable, Equatable {
    public var imageCount: Int
    public var images: [Image]

    public struct Image: Sendable, Equatable {
        public var index: Int
        public var name: String
        public var displayName: String?
        public var editionID: String?
        public var installationType: String?
        public var architecture: Architecture
        public var build: Int
        public var major: Int
        public var minor: Int
        public var spBuild: Int
        public var languages: [String]
        public var defaultLanguage: String?
        public var totalBytes: UInt64

        /// Windows 11 client, ARM64, 22H2 (build 22621) or newer (docs/03).
        public var unsupportedReasons: [String] {
            var r: [String] = []
            if architecture != .arm64 { r.append("architecture is \(architecture), Seemless needs arm64") }
            if build < 22621 { r.append("build \(build) is older than Windows 11 22H2 (22621)") }
            if let type = installationType, type != "Client" { r.append("installation type is \(type), not Client") }
            if editionID?.lowercased().contains("server") == true { r.append("Windows Server is not supported") }
            return r
        }

        public var isSupported: Bool { unsupportedReasons.isEmpty }
    }

    /// Values of `<WINDOWS><ARCH>` (PROCESSOR_ARCHITECTURE_*).
    public enum Architecture: Sendable, Equatable, CustomStringConvertible {
        case x86, arm, x64, arm64, other(Int)
        init(_ code: Int) {
            switch code { case 0: self = .x86; case 5: self = .arm; case 9: self = .x64; case 12: self = .arm64; default: self = .other(code) }
        }
        public var description: String {
            switch self {
            case .x86: return "x86"; case .arm: return "arm"; case .x64: return "x64"; case .arm64: return "arm64"
            case .other(let c): return "unknown(\(c))"
            }
        }
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case notWIM, truncated, badXML(String)
        public var description: String {
            switch self {
            case .notWIM: return "not a WIM/ESD file (bad magic)"
            case .truncated: return "file is truncated"
            case .badXML(let why): return "image catalogue XML is invalid: \(why)"
            }
        }
    }

    public static let magic = Array("MSWIM\0\0\0".utf8)
    static let headerSize = 208
    /// Offset of the XML data resource header inside the WIM header.
    static let xmlResourceOffset = 72
    static let imageCountOffset = 44
    /// Refuse absurd catalogue sizes from a corrupt or hostile file.
    static let maxXMLBytes: UInt64 = 64 << 20

    public static func read(_ url: URL) throws -> WIMInfo {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: headerSize), header.count == headerSize else {
            throw ParseError.truncated
        }
        guard Array(header.prefix(8)) == magic else { throw ParseError.notWIM }
        let count = Int(header.le32(at: imageCountOffset))
        // reshdr: u64 (size in low 56 bits | flags in top 8), u64 offset, u64 original size.
        let sizeAndFlags = header.le64(at: xmlResourceOffset)
        let size = sizeAndFlags & 0x00FF_FFFF_FFFF_FFFF
        let offset = header.le64(at: xmlResourceOffset + 8)
        guard size > 0, size <= maxXMLBytes else { throw ParseError.badXML("size \(size)") }
        try handle.seek(toOffset: offset)
        guard let xml = try handle.read(upToCount: Int(size)), xml.count == Int(size) else {
            throw ParseError.truncated
        }
        return try parseCatalogue(xml, declaredCount: count)
    }

    /// Parses the UTF-16LE `<WIM>` catalogue.
    static func parseCatalogue(_ data: Data, declaredCount: Int) throws -> WIMInfo {
        var bytes = data
        if bytes.starts(with: [0xFF, 0xFE]) { bytes = bytes.dropFirst(2) }
        guard let text = String(data: bytes, encoding: .utf16LittleEndian) else { throw ParseError.badXML("not UTF-16LE") }
        let doc: XMLDocument
        do { doc = try XMLDocument(xmlString: text, options: []) } catch {
            throw ParseError.badXML(error.localizedDescription)
        }
        let nodes = (try? doc.nodes(forXPath: "/WIM/IMAGE")) ?? []
        var images: [Image] = []
        for case let node as XMLElement in nodes {
            func text(_ path: String) -> String? {
                (try? node.nodes(forXPath: path))?.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            func int(_ path: String) -> Int { text(path).flatMap { Int($0) } ?? 0 }
            let langs = ((try? node.nodes(forXPath: "WINDOWS/LANGUAGES/LANGUAGE")) ?? []).compactMap(\.stringValue)
            images.append(Image(
                index: node.attribute(forName: "INDEX")?.stringValue.flatMap { Int($0) } ?? images.count + 1,
                name: text("NAME") ?? "",
                displayName: text("DISPLAYNAME"),
                editionID: text("WINDOWS/EDITIONID"),
                installationType: text("WINDOWS/INSTALLATIONTYPE"),
                architecture: Architecture(int("WINDOWS/ARCH")),
                build: int("WINDOWS/VERSION/BUILD"),
                major: int("WINDOWS/VERSION/MAJOR"),
                minor: int("WINDOWS/VERSION/MINOR"),
                spBuild: int("WINDOWS/VERSION/SPBUILD"),
                languages: langs,
                defaultLanguage: text("WINDOWS/LANGUAGES/DEFAULT"),
                totalBytes: UInt64(text("TOTALBYTES") ?? "") ?? 0))
        }
        return WIMInfo(imageCount: declaredCount, images: images.sorted { $0.index < $1.index })
    }

    /// The edition to install when the user does not choose: Pro, else the
    /// first supported image (docs/03).
    public var preferredImage: Image? {
        let supported = images.filter(\.isSupported)
        return supported.first { $0.editionID == "Professional" } ?? supported.first
    }
}

extension Data {
    func le32(at offset: Int) -> UInt32 {
        self[startIndex + offset ..< startIndex + offset + 4].enumerated()
            .reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }
    func le64(at offset: Int) -> UInt64 {
        self[startIndex + offset ..< startIndex + offset + 8].enumerated()
            .reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }
}
