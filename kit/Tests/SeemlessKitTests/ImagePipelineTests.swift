import Foundation
import Testing
@testable import SeemlessKit

/// The repository's image/ directory, found from this source file.
let repoAssets = ImageAssets(root: URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "image", directoryHint: .isDirectory))

func settings(_ mutate: (inout SetupPayload.Settings) -> Void = { _ in }) -> SetupPayload.Settings {
    var s = SetupPayload.Settings(imageIndex: 6, password: "correct-horse-battery", timeZone: "W. Europe Standard Time",
                                  language: "en-US")
    mutate(&s)
    return s
}

@Suite struct SetupPayloadRenderTests {
    @Test func rendersAllFilesWithNoPlaceholdersLeft() throws {
        let files = try SetupPayload(assets: repoAssets, settings: settings()).render()
        for path in ["autounattend.xml", "seemless/SEEMLESS.MARK", "seemless/apply.cmd", "seemless/config.cmd",
                     "seemless/unattend.xml", "seemless/SetupComplete.cmd", "seemless/firstboot.cmd"] {
            #expect(files[path] != nil, "\(path)")
        }
        for (path, data) in files {
            #expect(!String(decoding: data, as: UTF8.self).contains("{{"), "\(path) has an unfilled placeholder")
        }
    }

    @Test func answerFilesAreWellFormedXML() throws {
        let files = try SetupPayload(assets: repoAssets, settings: settings { $0.username = "Ana" }).render()
        for path in ["autounattend.xml", "seemless/unattend.xml"] {
            let doc = try XMLDocument(data: files[path]!)
            #expect(doc.rootElement()?.name == "unattend")
        }
        let unattend = try XMLDocument(data: files["seemless/unattend.xml"]!)
        func value(_ xpath: String) throws -> String? { try unattend.nodes(forXPath: xpath).first?.stringValue }
        #expect(try value("//*[local-name()='ComputerName']") == "SEEMLESS")
        #expect(try value("//*[local-name()='TimeZone']") == "W. Europe Standard Time")
        #expect(try value("//*[local-name()='LocalAccount']/*[local-name()='Name']") == "Ana")
        #expect(try value("//*[local-name()='AutoLogon']/*[local-name()='Username']") == "Ana")
    }

    @Test func licencePageShownUnlessExplicitlyAccepted() throws {
        func hide(_ accepted: Bool) throws -> String? {
            let files = try SetupPayload(assets: repoAssets, settings: settings { $0.hideLicensePage = accepted }).render()
            return try XMLDocument(data: files["seemless/unattend.xml"]!)
                .nodes(forXPath: "//*[local-name()='HideEULAPage']").first?.stringValue
        }
        #expect(try hide(false) == "false")
        #expect(try hide(true) == "true")
        #expect(SetupPayload.Settings(imageIndex: 1, password: "correct-horse-battery").hideLicensePage == false,
                "the default must show the licence page")
    }

    @Test func passwordIsEncodedNotPlain() throws {
        let files = try SetupPayload(assets: repoAssets, settings: settings()).render()
        let text = String(decoding: files["seemless/unattend.xml"]!, as: UTF8.self)
        #expect(!text.contains("correct-horse-battery"))
        let encoded = SetupPayload.encodeUnattendPassword("correct-horse-battery")
        #expect(text.contains(encoded))
        // Round trip: base64 -> UTF-16LE -> password + "Password".
        let raw = Data(base64Encoded: encoded)!
        #expect(String(data: raw, encoding: .utf16LittleEndian) == "correct-horse-batteryPassword")
    }

    @Test func configAndScriptsUseCRLF() throws {
        let files = try SetupPayload(assets: repoAssets, settings: settings { $0.compactOS = false }).render()
        let config = String(decoding: files["seemless/config.cmd"]!, as: UTF8.self)
        #expect(config.contains("set SL_INDEX=6\r\n"))
        #expect(config.contains("set SL_COMPACT=0\r\n"))
        for script in ["seemless/apply.cmd", "seemless/firstboot.cmd", "seemless/config.cmd"] {
            let bytes = [UInt8](files[script]!)
            let lfs = bytes.indices.filter { bytes[$0] == 0x0A }
            #expect(!lfs.isEmpty && lfs.allSatisfy { $0 > 0 && bytes[$0 - 1] == 0x0D }, "\(script) must be CRLF only")
        }
    }

    @Test func rejectsUnsafeSettings() {
        let bad = settings {
            $0.computerName = "this-name-is-way-too-long"
            $0.username = "Administrator"
            $0.password = "short"
            $0.language = "en_US<x>"
            $0.recipeName = "../../etc"
        }
        #expect(bad.validationErrors.count == 5)
        #expect(throws: SetupPayload.PayloadError.self) { try SetupPayload(assets: repoAssets, settings: bad).render() }
    }

    @Test func xmlSpecialCharactersAreEscaped() {
        #expect(SetupPayload.xmlEscape(#"a<b>&"c'"#) == "a&lt;b&gt;&amp;&quot;c&apos;")
    }

    @Test func generatedPasswordsAreValidAndDistinct() {
        let a = WindowsCredentials.generatePassword(), b = WindowsCredentials.generatePassword()
        #expect(a.count == 24 && a != b)
        #expect(settings { $0.password = a }.validationErrors.isEmpty)
    }

    @Test func timeZoneMapping() {
        #expect(WindowsTimeZone.forIANA("Europe/Berlin") == "W. Europe Standard Time")
        #expect(WindowsTimeZone.forIANA("America/Los_Angeles") == "Pacific Standard Time")
        #expect(WindowsTimeZone.forIANA("Mars/Olympus_Mons") == "UTC")
    }
}

/// Real disk images through hdiutil/diskutil. Serialized: attaching many
/// images at once is slow and noisy.
@Suite(.serialized) struct DiskImageTests {
    @Test func payloadDiskRoundTrip() async throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appending(path: "setup-payload.img")
        let drivers = dir.appending(path: "drv", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: drivers, withIntermediateDirectories: true)
        try Data("[Version]\r\n".utf8).write(to: drivers.appending(path: "test.inf"))

        let payload = SetupPayload(assets: repoAssets, settings: settings())
        try await payload.writeDiskImage(to: image, sizeMiB: 64, extraDirectories: ["seemless/drivers": drivers])

        // Check the disk is MBR + FAT32 and holds the files, unchanged.
        let expected = try payload.render()
        try await FATImage.withMounted(image, readOnly: true) { root in
            for (rel, data) in expected {
                #expect(FileManager.default.contents(atPath: root.appending(path: rel).path(percentEncoded: false)) == data, "\(rel)")
            }
            #expect(FileManager.default.fileExists(atPath: root.appending(path: "seemless/drivers/test.inf").path(percentEncoded: false)))
            let names = try FileManager.default.subpathsOfDirectory(atPath: root.path(percentEncoded: false))
            #expect(!names.contains { ($0 as NSString).lastPathComponent.hasPrefix("._") }, "no AppleDouble files")
        }

        // Simulate the guest writing results, then collect them.
        try await FATImage.withMounted(image, readOnly: false) { root in
            try Data("FIRSTBOOT_OK\r\n".utf8).write(to: root.appending(path: "seemless/result/status.txt"))
            try Data("log\r\n".utf8).write(to: root.appending(path: "seemless/result/apply.log"))
        }
        let out = dir.appending(path: "result", directoryHint: .isDirectory)
        let result = try await SetupPayload.collectResult(from: image, into: out)
        #expect(result.status == "FIRSTBOOT_OK")
        #expect(result.succeeded)
        #expect(result.files == ["apply.log", "status.txt"])
    }

    @Test func emptyResultMeansApplyNeverRan() async throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appending(path: "p.img")
        try await SetupPayload(assets: repoAssets, settings: settings()).writeDiskImage(to: image, sizeMiB: 64)
        let result = try await SetupPayload.collectResult(from: image, into: dir.appending(path: "r"))
        #expect(result.status == nil && result.files.isEmpty && !result.succeeded)
    }

    /// An ISO built on the fly with a synthetic sources/install.wim.
    @Test func inspectsISO() async throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let tree = dir.appending(path: "tree/sources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        let xml = "<WIM>" + windowsImageXML(index: 1, edition: "Core") + windowsImageXML(index: 6, edition: "Professional") + "</WIM>"
        try syntheticWIM(xml: xml, imageCount: 2).write(to: tree.appending(path: "install.wim"))
        let iso = dir.appending(path: "win.iso")
        try await ProcessRunner.run(URL(filePath: "/usr/bin/hdiutil"),
                                    ["makehybrid", "-quiet", "-udf", "-o", iso.path(percentEncoded: false),
                                     dir.appending(path: "tree").path(percentEncoded: false)])
        let inspection = try await ISOMedia.inspect(iso)
        #expect(inspection.installImagePath == "sources/install.wim")
        #expect(inspection.wim.preferredImage?.index == 6)

        // A non-Windows ISO is rejected clearly.
        try FileManager.default.removeItem(at: tree.appending(path: "install.wim"))
        try Data("x".utf8).write(to: tree.appending(path: "other.txt"))
        let plain = dir.appending(path: "plain.iso")
        try await ProcessRunner.run(URL(filePath: "/usr/bin/hdiutil"),
                                    ["makehybrid", "-quiet", "-udf", "-o", plain.path(percentEncoded: false),
                                     dir.appending(path: "tree").path(percentEncoded: false)])
        await #expect(throws: ISOMedia.MediaError.self) { _ = try await ISOMedia.inspect(plain) }
    }

    @Test func builderChoosesSupportedEdition() throws {
        let builder = ImageBuilder(layout: StorageLayout(root: URL(filePath: "/tmp/x")),
                                   stack: HostStack(prefix: URL(filePath: "/p")), assets: repoAssets)
        let info = WIMInfo(imageCount: 2, images: [
            .init(index: 1, name: "x64 Pro", editionID: "Professional", installationType: "Client", architecture: .x64,
                  build: 26100, major: 10, minor: 0, spBuild: 1, languages: [], totalBytes: 0),
            .init(index: 2, name: "arm64 Pro", editionID: "Professional", installationType: "Client", architecture: .arm64,
                  build: 26100, major: 10, minor: 0, spBuild: 1, languages: [], totalBytes: 0),
        ])
        #expect(try builder.choose(from: info, index: nil).index == 2)
        #expect(throws: ImageBuilder.BuildError.self) { try builder.choose(from: info, index: 1) }
        #expect(throws: ImageBuilder.BuildError.self) { try builder.choose(from: info, index: 9) }
    }
}
