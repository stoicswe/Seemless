import Foundation
import Testing
@testable import SeemlessKit

/// Checks the removal recipes against the DISM inventory of a real image
/// (image/recipes/README.md: "Lists come from real images, never from memory").
@Suite struct RecipeTests {
    static let recipes = ["seemless-default", "seemless-gaming"]

    /// Apps every recipe must keep (docs/03 "Gaming and compatibility keeps").
    static let keepAppx = [
        "Microsoft.WindowsStore", "Microsoft.StorePurchaseApp", "Microsoft.DesktopAppInstaller",
        "Microsoft.SecHealthUI", "Microsoft.ApplicationCompatibilityEnhancements",
        "Microsoft.VCLibs", "Microsoft.UI.Xaml", "Microsoft.NET",
        "Microsoft.AV1VideoExtension", "Microsoft.HEVCVideoExtension", "Microsoft.HEIFImageExtension",
        "Microsoft.VP9VideoExtensions", "Microsoft.WebMediaExtensions", "Microsoft.WebpImageExtension",
        "Microsoft.MPEG2VideoExtension", "Microsoft.RawImageExtension", "Microsoft.AVCEncoderVideoExtension",
    ]
    static let keepCapabilities = ["DirectX.Configuration.Database", "VBSCRIPT", "OpenSSH.Client"]
    static let keepPaths = ["EdgeWebView"]

    struct Inventory {
        var appx: [String]
        var capabilities: [String: String]
        var features: [String: String]
    }

    static var inventoryRoot: URL { repoAssets.root.appending(path: "recipes/inventory", directoryHint: .isDirectory) }

    /// The newest inventory (directories are named `<build>-<edition>-<arch>`).
    static func latestInventory() throws -> (String, Inventory) {
        let dirs = try FileManager.default.contentsOfDirectory(atPath: inventoryRoot.path(percentEncoded: false))
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        let name = try #require(dirs.last, "no inventory under image/recipes/inventory")
        let dir = inventoryRoot.appending(path: name, directoryHint: .isDirectory)
        func text(_ f: String) throws -> String { try String(contentsOf: dir.appending(path: f), encoding: .utf8) }

        let appx = try text("appx.txt").split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "PackageName" else { return nil }
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        func states(_ file: String, key: String) throws -> [String: String] {
            var result: [String: String] = [:]
            var current: String?
            for line in try text(file).split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                if parts[0] == key { current = parts[1] }
                if parts[0] == "State", let c = current { result[c] = parts[1]; current = nil }
            }
            return result
        }
        return (name, Inventory(appx: appx,
                                capabilities: try states("capabilities.txt", key: "Capability Identity"),
                                features: try states("features.txt", key: "Feature Name")))
    }

    static func list(_ recipe: String, _ file: String) -> [String] {
        let url = repoAssets.recipe(recipe).appending(path: file)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    @Test func inventoryParses() throws {
        let (_, inv) = try Self.latestInventory()
        #expect(inv.appx.count > 30)
        #expect(inv.capabilities.count > 100)
        #expect(inv.features.count > 50)
    }

    @Test(arguments: recipes) func appxPrefixesMatchTheImageAndSpareTheKeeps(_ recipe: String) throws {
        let (build, inv) = try Self.latestInventory()
        let prefixes = Self.list(recipe, "remove-appx.txt")
        #expect(!prefixes.isEmpty)
        for p in prefixes {
            #expect(inv.appx.contains { $0.lowercased().hasPrefix(p.lowercased()) }, "\(recipe): \(p) matches nothing in \(build)")
            for keep in Self.keepAppx {
                #expect(!keep.lowercased().hasPrefix(p.lowercased()), "\(recipe): \(p) would remove keep \(keep)")
            }
        }
        #expect(Set(prefixes).count == prefixes.count, "\(recipe): duplicate prefixes")
    }

    @Test(arguments: recipes) func capabilitiesAreInstalledInTheImage(_ recipe: String) throws {
        let (build, inv) = try Self.latestInventory()
        for c in Self.list(recipe, "remove-capabilities.txt") {
            #expect(inv.capabilities[c] == "Installed", "\(recipe): \(c) is \(inv.capabilities[c] ?? "absent") in \(build)")
            #expect(!Self.keepCapabilities.contains { c.hasPrefix($0) }, "\(recipe): \(c) is a keep")
        }
    }

    @Test(arguments: recipes) func featuresAreEnabledInTheImage(_ recipe: String) throws {
        let (build, inv) = try Self.latestInventory()
        for f in Self.list(recipe, "disable-features.txt") {
            #expect(inv.features[f] == "Enabled", "\(recipe): \(f) is \(inv.features[f] ?? "absent") in \(build)")
        }
    }

    @Test(arguments: recipes) func deletePathsAreRelativeAndSpareTheKeeps(_ recipe: String) {
        for p in Self.list(recipe, "delete-paths.txt") {
            #expect(!p.contains(":") && !p.hasPrefix("\\") && !p.contains(".."), "\(recipe): \(p) must be relative")
            #expect(!Self.keepPaths.contains { p.contains($0) }, "\(recipe): \(p) is a keep")
            #expect(!p.lowercased().hasPrefix("windows\\winsxs"), "\(recipe): never delete the component store")
        }
    }

    @Test(arguments: recipes) func registryFilesTargetOnlyTheLoadedOfflineHives(_ recipe: String) throws {
        let dir = repoAssets.recipe(recipe).appending(path: "registry", directoryHint: .isDirectory)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)).filter { $0.hasSuffix(".reg") }
        #expect(!files.isEmpty)
        let hives = ["SOFTWARE", "SYSTEM", "DEFAULT", "NTUSER"].map { "[HKEY_LOCAL_MACHINE\\zSEEMLESS_\($0)\\" }
        for f in files {
            let data = try Data(contentsOf: dir.appending(path: f))
            #expect(data.allSatisfy { $0 < 0x80 }, "\(f): ASCII only (the payload converts line endings byte-wise)")
            let text = String(decoding: data, as: UTF8.self)
            #expect(text.hasPrefix("Windows Registry Editor Version 5.00\n"), "\(f): header")
            for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("[") {
                #expect(hives.contains { line.hasPrefix($0) }, "\(f): \(line) is outside the offline hives")
            }
            #expect(!text.contains("CurrentControlSet"), "\(f): offline SYSTEM has ControlSet001, not CurrentControlSet")
        }
    }

    /// seemless-gaming = seemless-default minus the Xbox apps and legacy WMP.
    @Test func gamingDiffersFromDefaultOnlyByTheGamingKeeps() throws {
        let appxDiff = Set(Self.list("seemless-default", "remove-appx.txt")).subtracting(Self.list("seemless-gaming", "remove-appx.txt"))
        #expect(appxDiff.allSatisfy { $0.hasPrefix("Microsoft.Xbox") } && !appxDiff.isEmpty)
        #expect(Set(Self.list("seemless-gaming", "remove-appx.txt")).isSubset(of: Self.list("seemless-default", "remove-appx.txt")))
        let capDiff = Set(Self.list("seemless-default", "remove-capabilities.txt")).subtracting(Self.list("seemless-gaming", "remove-capabilities.txt"))
        #expect(capDiff == ["Media.WindowsMediaPlayer~~~~0.0.12.0"])
        for f in ["disable-features.txt", "delete-paths.txt"] {
            #expect(Self.list("seemless-default", f) == Self.list("seemless-gaming", f), "\(f) differs")
        }
        for f in ["registry/policies.reg", "registry/default-user.reg"] {
            let a = try Data(contentsOf: repoAssets.recipe("seemless-default").appending(path: f))
            let b = try Data(contentsOf: repoAssets.recipe("seemless-gaming").appending(path: f))
            #expect(a == b, "\(f) differs")
        }
    }

    /// A `call :label` without a matching `:label` only prints an error to the
    /// WinPE console, never to the log (it silently skipped every recipe step
    /// once). Check every script statically.
    @Test(arguments: ["apply.cmd", "firstboot.cmd", "SetupComplete.cmd"])
    func everyCalledLabelExists(_ script: String) throws {
        let text = try String(contentsOf: repoAssets.root.appending(path: "winpe/\(script)"), encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let defined = Set(lines.filter { $0.hasPrefix(":") && !$0.hasPrefix("::") }
            .map { String($0.dropFirst()).split(separator: " ").first.map(String.init)?.lowercased() ?? "" })
        let called = Set(text.matches(of: /(?i)\b(?:call|goto)\s+:(\w+)/).map { String($0.1).lowercased() })
            .subtracting(["eof"])
        #expect(called.isSubset(of: defined), "\(script): undefined labels \(called.subtracting(defined).sorted())")
    }

    @Test(arguments: recipes) func recipeRendersIntoThePayloadWithCRLF(_ recipe: String) throws {
        let files = try SetupPayload(assets: repoAssets, settings: settings { $0.recipeName = recipe }).render()
        for name in ["remove-appx.txt", "remove-capabilities.txt", "disable-features.txt", "delete-paths.txt",
                     "registry/policies.reg", "registry/default-user.reg"] {
            let data = try #require(files["seemless/recipe/\(name)"], "\(recipe)/\(name)")
            let text = String(decoding: data, as: UTF8.self)
            #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "\(name) must be CRLF in the payload")
        }
        #expect(files["seemless/recipe/README.md"] == nil)
    }
}

@Suite struct InstallProfileTests {
    @Test func everyProfileHasARecipeDirectory() {
        for p in InstallProfile.allCases {
            let dir = repoAssets.recipe(p.recipe).path(percentEncoded: false)
            #expect(FileManager.default.fileExists(atPath: dir), "\(p): \(dir)")
            #expect(InstallProfile(recipe: p.recipe) == p)
        }
    }

    /// "Fat" is stock Windows: the recipe must not remove or change anything.
    @Test func fatRendersNoRecipeFiles() throws {
        let files = try SetupPayload(assets: repoAssets, settings: settings { $0.recipeName = InstallProfile.fat.recipe }).render()
        #expect(!files.keys.contains { $0.hasPrefix("seemless/recipe/") }, "\(files.keys.filter { $0.hasPrefix("seemless/recipe/") })")
    }
}
