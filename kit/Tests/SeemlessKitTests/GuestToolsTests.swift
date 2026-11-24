import Foundation
import Testing
@testable import SeemlessKit

@Suite struct GuestToolsTests {
    private func makeTools(version: String?, exes: Bool = true) throws -> GuestTools {
        let root = FileManager.default.temporaryDirectory.appending(path: "guest-tools-\(UUID().uuidString)", directoryHint: .isDirectory)
        let tools = GuestTools(root: root)
        try FileManager.default.createDirectory(at: tools.agentDirectory, withIntermediateDirectories: true)
        if exes {
            for f in ["seemless-agent-svc.exe", "seemless-agent.exe", "install.cmd"] {
                try Data("x".utf8).write(to: tools.agentDirectory.appending(path: f))
            }
        }
        if let version { try Data(version.utf8).write(to: tools.agentDirectory.appending(path: "version.txt")) }
        return tools
    }

    @Test func versionComesFromTheHelloBuild() {
        #expect(GuestTools.version(fromBuild: "seemless-agent-svc 0.0.2 (8bc3fb59e430)") == "0.0.2 (8bc3fb59e430)")
        #expect(GuestTools.version(fromBuild: "seemless-agent-svc 0.0.2 (8bc3fb59e430+dirty)") == "0.0.2 (8bc3fb59e430+dirty)")
        #expect(GuestTools.version(fromBuild: "nospace") == "nospace")
    }

    @Test func versionFileIsTrimmedAndBounded() throws {
        let ok = try makeTools(version: "0.0.2 (abc)\r\n")
        defer { try? FileManager.default.removeItem(at: ok.root) }
        #expect(ok.version == "0.0.2 (abc)")
        #expect(ok.hasAgent)
        #expect(!ok.hasISO)

        for bad in ["", "   ", String(repeating: "9", count: 65), "1\u{1b}[2J", String(repeating: " ", count: 300) + "1"] {
            let t = try makeTools(version: bad)
            defer { try? FileManager.default.removeItem(at: t.root) }
            #expect(t.version == nil, "\(bad.debugDescription) accepted")
        }
        let none = try makeTools(version: nil, exes: false)
        defer { try? FileManager.default.removeItem(at: none.root) }
        #expect(none.version == nil)
        #expect(!none.hasAgent)
    }

    @Test func locateFindsEnvironmentAndRepositoryFolders() throws {
        let tools = try makeTools(version: "1")
        defer { try? FileManager.default.removeItem(at: tools.root) }
        #expect(GuestTools.locate(environment: ["SEEMLESS_GUEST_TOOLS": tools.root.path(percentEncoded: false)]) == tools)

        let empty = try makeTools(version: "1", exes: false)
        defer { try? FileManager.default.removeItem(at: empty.root) }
        #expect(GuestTools.locate(environment: ["SEEMLESS_GUEST_TOOLS": empty.root.path(percentEncoded: false)]) == nil,
                "a folder without the agent binaries does not count")

        // <repo>/build/guest-tools found from a working directory inside the repo.
        let repo = FileManager.default.temporaryDirectory.appending(path: "repo-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: repo) }
        let inRepo = GuestTools(root: repo.appending(path: "build/guest-tools", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: inRepo.agentDirectory, withIntermediateDirectories: true)
        for f in ["seemless-agent-svc.exe", "seemless-agent.exe", "install.cmd"] {
            try Data("x".utf8).write(to: inRepo.agentDirectory.appending(path: f))
        }
        let cwd = repo.appending(path: "kit/Sources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let found = GuestTools.locate(environment: [:], executable: URL(filePath: "/nonexistent/bin/x"), currentDirectory: cwd)
        #expect(found?.root.standardizedFileURL.path == inRepo.root.standardizedFileURL.path)
    }
}
