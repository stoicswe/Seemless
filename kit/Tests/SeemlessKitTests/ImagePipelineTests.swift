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
        #expect(try value("//*[local-name()='AutoLogon']/*[local-name()='Username']") == "Ana")
    }

    /// S4: SetupComplete/firstboot run before OOBE, so the answer file must
    /// survive them. It is deleted at the first logon by a SYSTEM task (a
    /// FirstLogonCommand runs as the user and cannot delete from Panther:
    /// seen on build 26300, where the file was still there after logon).
    @Test func answerFileDeletedAtFirstLogonNotBeforeOOBE() throws {
        let files = try SetupPayload(assets: repoAssets, settings: settings()).render()
        let firstboot = String(decoding: files["seemless/firstboot.cmd"]!, as: UTF8.self)
        let commands = firstboot.split(whereSeparator: \.isNewline).filter { !$0.lowercased().hasPrefix("rem") }
        #expect(!commands.contains { line in
            let l = line.lowercased()
            return l.contains("unattend") && (l.contains("del ") || l.contains("erase ") || l.contains("move "))
        }, "firstboot.cmd must not remove an answer file (it reads the payload copy)")
        let script = String(decoding: try #require(files["seemless/guest/setup-account.ps1"]), as: UTF8.self)
        #expect(script.contains(#"del /f /q "%WINDIR%\Panther\unattend.xml""#))
        #expect(script.contains("New-ScheduledTaskTrigger -AtLogOn"))
        #expect(script.contains("-UserId 'S-1-5-18'"), "the cleanup runs as SYSTEM")
        let unattend = try XMLDocument(data: files["seemless/unattend.xml"]!)
        #expect(try unattend.nodes(forXPath: "//*[local-name()='FirstLogonCommands']").isEmpty,
                "a user-context FirstLogonCommand cannot delete the answer file")
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

@Suite struct LocalAccountTests {
    @Test func usernameRules() {
        for ok in ["Seemless", "ana", "dev.user", "a_b-c", String(repeating: "x", count: 20)] {
            #expect(SetupPayload.Settings.isValidUsername(ok), "\(ok)")
        }
        for bad in ["", "Administrator", "guest", "has space", "a@b", String(repeating: "x", count: 21), "WDAGUtilityAccount"] {
            #expect(!SetupPayload.Settings.isValidUsername(bad), "\(bad)")
        }
    }

    /// The account is local and never comes from OOBE: the answer file hides
    /// both account pages, has no account to create and no Microsoft-account
    /// settings; it only carries auto-logon, which setup-account.ps1 reads.
    @Test func answerFileOnlyHidesAccountPagesAndSetsAutoLogon() throws {
        let files = try SetupPayload(assets: repoAssets, settings: settings { $0.username = "ana" }).render()
        let doc = try XMLDocument(data: files["seemless/unattend.xml"]!)
        func value(_ x: String) throws -> String? { try doc.nodes(forXPath: x).first?.stringValue }
        #expect(try doc.nodes(forXPath: "//*[local-name()='LocalAccounts' or local-name()='UserAccounts']").isEmpty,
                "OOBE ignored <Group>Administrators</Group> on 26300; the account is made by setup-account.ps1")
        #expect(try value("//*[local-name()='HideLocalAccountScreen']") == "true")
        #expect(try value("//*[local-name()='HideOnlineAccountScreens']") == "true")
        #expect(try value("//*[local-name()='AutoLogon']/*[local-name()='Enabled']") == "true")
        #expect(try value("//*[local-name()='AutoLogon']/*[local-name()='Username']") == "ana")
        #expect(try value("//*[local-name()='AutoLogon']//*[local-name()='Value']")
                == SetupPayload.encodeUnattendPassword("correct-horse-battery"))
        #expect(try doc.nodes(forXPath: "//*[local-name()='MicrosoftAccount' or local-name()='OnlineAccount']").isEmpty)
    }

    /// S6b: with Fast Startup on, a "shut down" is a hibernate and the next
    /// start a resume, which crashed (HVF ERRIDR_EL1) and, with viogpu3d, does
    /// not restore the display: `wp31` and `admfix` ended in Startup Repair.
    /// Every image, whatever its recipe, turns it off before FIRSTBOOT_OK,
    /// and keeps hibernation itself (suspend to disk, S6).
    @Test func firstbootDisablesFastStartup() throws {
        let files = try SetupPayload(assets: repoAssets, settings: settings()).render()
        let firstboot = String(decoding: files["seemless/firstboot.cmd"]!, as: UTF8.self)
        let commands = firstboot.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.lowercased().hasPrefix("rem") }
        let set = try #require(commands.first { $0.hasPrefix("reg add") && $0.contains("HiberbootEnabled") })
        #expect(set.contains(#""HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power""#))
        #expect(set.contains("/t REG_DWORD /d 0 /f"))
        #expect(!commands.contains { $0.lowercased().contains("powercfg") && $0.lowercased().contains("/h off") },
                "hibernation stays available for suspend to disk (S6)")
        let reg = try #require(firstboot.range(of: "HiberbootEnabled /t REG_DWORD"))
        let ok = try #require(firstboot.range(of: "echo FIRSTBOOT_OK"))
        #expect(reg.lowerBound < ok.lowerBound)
        #expect(firstboot.contains("else if not defined FASTSTARTUP_OK ("), "a failure is the build result")
        #expect(firstboot.contains("echo ERROR faststartup "))
        // Recipe-independent: the stock (Fat) recipe has no registry files.
        #expect(!FileManager.default.fileExists(
            atPath: repoAssets.root.appending(path: "recipes/stock/registry").path(percentEncoded: false)))
    }

    /// The account is created as SYSTEM before OOBE and added to the groups by
    /// SID; firstboot reports a failure instead of FIRSTBOOT_OK.
    @Test func firstbootCreatesTheAdministratorAccount() throws {
        let files = try SetupPayload(assets: repoAssets, settings: settings()).render()
        let script = String(decoding: try #require(files["seemless/guest/setup-account.ps1"]), as: UTF8.self)
        #expect(script.contains("u:AutoLogon"), "name and password come from the answer file's AutoLogon")
        #expect(script.contains("'Password'.Length"), "strips the unattend encoding's suffix")
        #expect(script.contains("'S-1-5-32-544'") && script.contains("'S-1-5-32-545'"),
                "Administrators and Users by SID, so it works in every Windows language")
        #expect(script.contains("is not in Administrators after adding it"), "verifies instead of trusting")
        // New-LocalUser rejects descriptions over 48 characters (seen on 26300).
        let description = try #require(script.firstMatch(of: /-Description '([^']*)'/)?.1)
        #expect(description.count <= 48)

        let firstboot = String(decoding: files["seemless/firstboot.cmd"]!, as: UTF8.self)
        let account = try #require(firstboot.range(of: #"Seemless\setup-account.ps1"#))
        let ok = try #require(firstboot.range(of: "echo FIRSTBOOT_OK"))
        #expect(account.lowerBound < ok.lowerBound)
        #expect(firstboot.contains("if not defined ACCOUNT_OK ("))
        // Setup rewrites the passwords in Panther's cached copy (26300), so
        // the script must read the payload disk's original.
        #expect(firstboot.contains(#"-AnswerFile "%P%\seemless\unattend.xml""#))
        #expect(files["seemless/unattend.xml"] != nil)
        #expect(firstboot.contains("echo ERROR account "))

        // apply.cmd puts every rendered guest script where firstboot looks.
        let apply = String(decoding: files["seemless/apply.cmd"]!, as: UTF8.self)
        for path in files.keys where path.hasPrefix("seemless/guest/") {
            let name = String(path.dropFirst("seemless/guest/".count))
            #expect(apply.contains(#"\guest\\#(name)" "%W%\ProgramData\Seemless\\#(name)""#), "\(name)")
        }
    }
}
