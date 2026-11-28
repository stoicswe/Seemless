import Foundation
import Testing
@testable import SeemlessKit

/// The experimental WacOS option (Image/WacOS.swift, docs/03 "Optional: WacOS").
@Suite struct WacOSTests {
    @Test func pinnedReleaseIsValid() {
        #expect(WacOSRelease.pinned.validationErrors.isEmpty)
    }

    @Test func releaseFromAnotherHostOrTagIsRejected() {
        var r = WacOSRelease.pinned
        r.url = "https://example.com/renzyxx/WacOS/releases/download/build-46/WacOS.zip"
        #expect(!r.validationErrors.isEmpty)
        r = .pinned
        r.url = "https://github.com/renzyxx/WacOS/releases/download/build-99/WacOS-2026-11-24.zip"
        #expect(!r.validationErrors.isEmpty, "url must belong to the pinned tag")
        r = .pinned
        r.url = "https://github.com/renzyxx/WacOS/releases/download/build-46/x.zip\"; calc; \".zip"
        #expect(!r.validationErrors.isEmpty)
        r = .pinned
        r.sha256 = String(repeating: "A", count: 64)
        #expect(!r.validationErrors.isEmpty, "uppercase or wrong hex is refused")
        r = .pinned
        r.tag = "build 46"
        #expect(!r.validationErrors.isEmpty)
    }

    @Test func payloadHasNoWacOSFilesUnlessChosen() throws {
        let files = try SetupPayload(assets: repoAssets, settings: settings()).render()
        #expect(!files.keys.contains { $0.hasPrefix("seemless/wacos/") })
    }

    @Test func payloadCarriesScriptAndPinWhenChosen() throws {
        let files = try SetupPayload(assets: repoAssets, settings: settings { $0.wacos = .pinned }).render()
        let script = try #require(files["seemless/wacos/install-wacos.ps1"])
        #expect(String(decoding: script, as: UTF8.self).contains("\r\n"), "PowerShell file gets CRLF like the others")
        let json = try #require(files["seemless/wacos/wacos.json"])
        #expect(try JSONDecoder().decode(WacOSRelease.self, from: json) == .pinned)
        #expect(String(decoding: json, as: UTF8.self).contains("https://github.com/renzyxx/WacOS/releases/download/"),
                "slashes unescaped, so the guest's regex sees the real URL")
    }

    @Test func invalidReleaseFailsPayloadValidation() {
        var bad = WacOSRelease.pinned
        bad.sha256 = "nope"
        #expect(throws: SetupPayload.PayloadError.self) {
            try SetupPayload(assets: repoAssets, settings: settings { $0.wacos = bad }).render()
        }
    }

    @Test func buildNeedsLicenceAndNetwork() throws {
        var request = ImageBuilder.Request(iso: URL(filePath: "/x.iso"), vm: VMConfig(name: "w"))
        try ImageBuilder.checkWacOS(request)  // no WacOS: nothing to check
        request.wacos = .pinned
        #expect(throws: ImageBuilder.BuildError.self) { try ImageBuilder.checkWacOS(request) }
        request.acceptWacOSLicense = true
        try ImageBuilder.checkWacOS(request)
        request.vm.quarantine = .isolated
        #expect(throws: ImageBuilder.BuildError.self) { try ImageBuilder.checkWacOS(request) }
        request.vm.quarantine?.network = true
        try ImageBuilder.checkWacOS(request)
    }

    @Test func configRoundTripsAndOldConfigsDecodeWithout() throws {
        var c = VMConfig(name: "w")
        #expect(!c.hasWacOS)
        c.wacos = .pinned
        let back = try JSONDecoder().decode(VMConfig.self, from: JSONEncoder().encode(c))
        #expect(back.wacos == .pinned && back.hasWacOS)
        var plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(VMConfig(name: "old"))) as! [String: Any]
        plain.removeValue(forKey: "wacos")
        let old = try JSONDecoder().decode(VMConfig.self, from: JSONSerialization.data(withJSONObject: plain))
        #expect(!old.hasWacOS)
    }

    @Test func guestScriptChecksTheSameThingsAsTheHost() throws {
        let text = try String(contentsOf: repoAssets.guest.appending(path: ImageAssets.wacosScript), encoding: .utf8)
        #expect(text.contains("Get-FileHash -Algorithm SHA256"))
        #expect(text.contains("^https://github\\.com/renzyxx/WacOS/releases/download/"))
        #expect(text.contains("-RunLevel Limited"), "WacOS installs per user; the task never runs elevated")
        #expect(text.contains("--proto '=https'"))
    }
}
