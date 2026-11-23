import Foundation
import Testing
@testable import SeemlessKit

/// Builds a minimal WIM: a 208-byte header whose XML resource header points
/// at a UTF-16LE catalogue placed after some filler (like real files, where
/// the XML sits near the end).
func syntheticWIM(xml: String, imageCount: Int, filler: Int = 4096, corruptMagic: Bool = false) -> Data {
    var catalogue = Data([0xFF, 0xFE])
    catalogue.append(xml.data(using: .utf16LittleEndian)!)
    var header = Data(count: 208)
    let magic = corruptMagic ? Array("NOTAWIM\0".utf8) : WIMInfo.magic
    header.replaceSubrange(0..<8, with: magic)
    func put32(_ v: UInt32, _ at: Int) { for i in 0..<4 { header[at + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) } }
    func put64(_ v: UInt64, _ at: Int) { for i in 0..<8 { header[at + i] = UInt8((v >> (8 * UInt64(i))) & 0xFF) } }
    put32(208, 8)
    put32(UInt32(imageCount), 44)
    let xmlOffset = UInt64(208 + filler)
    put64(UInt64(catalogue.count), 72)          // size, flags = 0
    put64(xmlOffset, 80)                         // offset
    put64(UInt64(catalogue.count), 88)          // original size
    return header + Data(count: filler) + catalogue
}

func windowsImageXML(index: Int, edition: String, arch: Int = 12, build: Int = 26100, type: String = "Client") -> String {
    """
    <IMAGE INDEX="\(index)"><TOTALBYTES>20000000000</TOTALBYTES>
    <WINDOWS><ARCH>\(arch)</ARCH><EDITIONID>\(edition)</EDITIONID><INSTALLATIONTYPE>\(type)</INSTALLATIONTYPE>
    <LANGUAGES><LANGUAGE>en-US</LANGUAGE><DEFAULT>en-US</DEFAULT></LANGUAGES>
    <VERSION><MAJOR>10</MAJOR><MINOR>0</MINOR><BUILD>\(build)</BUILD><SPBUILD>1742</SPBUILD></VERSION></WINDOWS>
    <NAME>Windows 11 \(edition)</NAME><DISPLAYNAME>Windows 11 \(edition)</DISPLAYNAME></IMAGE>
    """
}

@Suite struct WIMInfoTests {
    func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "seemless-\(UUID().uuidString.prefix(8)).wim")
        try data.write(to: url)
        return url
    }

    @Test func readsCatalogueAndPrefersPro() throws {
        let xml = "<WIM><TOTALBYTES>1</TOTALBYTES>"
            + windowsImageXML(index: 1, edition: "Core")
            + windowsImageXML(index: 6, edition: "Professional")
            + "</WIM>"
        let url = try write(syntheticWIM(xml: xml, imageCount: 2)); defer { try? FileManager.default.removeItem(at: url) }
        let info = try WIMInfo.read(url)
        #expect(info.imageCount == 2)
        #expect(info.images.map(\.index) == [1, 6])
        let pro = try #require(info.preferredImage)
        #expect(pro.index == 6)
        #expect(pro.architecture == .arm64)
        #expect(pro.build == 26100 && pro.spBuild == 1742)
        #expect(pro.languages == ["en-US"])
        #expect(pro.totalBytes == 20_000_000_000)
        #expect(pro.isSupported)
    }

    @Test func rejectsX64OldAndServer() throws {
        let xml = "<WIM>"
            + windowsImageXML(index: 1, edition: "Professional", arch: 9)
            + windowsImageXML(index: 2, edition: "Professional", build: 22000)
            + windowsImageXML(index: 3, edition: "ServerStandard", type: "Server")
            + "</WIM>"
        let url = try write(syntheticWIM(xml: xml, imageCount: 3)); defer { try? FileManager.default.removeItem(at: url) }
        let info = try WIMInfo.read(url)
        #expect(info.images[0].unsupportedReasons == ["architecture is x64, Seemless needs arm64"])
        #expect(info.images[1].unsupportedReasons.first?.contains("22621") == true)
        #expect(info.images[2].unsupportedReasons.count == 2)
        #expect(info.preferredImage == nil)
    }

    @Test func rejectsNonWIMAndTruncated() throws {
        let bad = try write(syntheticWIM(xml: "<WIM/>", imageCount: 0, corruptMagic: true))
        defer { try? FileManager.default.removeItem(at: bad) }
        #expect(throws: WIMInfo.ParseError.notWIM) { try WIMInfo.read(bad) }

        let short = try write(Data(WIMInfo.magic + [0, 0]))
        defer { try? FileManager.default.removeItem(at: short) }
        #expect(throws: WIMInfo.ParseError.truncated) { try WIMInfo.read(short) }

        var cut = syntheticWIM(xml: "<WIM>" + windowsImageXML(index: 1, edition: "Professional") + "</WIM>", imageCount: 1)
        cut.removeLast(100)
        let cutURL = try write(cut); defer { try? FileManager.default.removeItem(at: cutURL) }
        #expect(throws: WIMInfo.ParseError.truncated) { try WIMInfo.read(cutURL) }
    }
}
