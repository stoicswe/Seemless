import Foundation
import Testing
@testable import SeemlessKit

@Suite struct StorageLayoutTests {
    let layout = StorageLayout(root: URL(filePath: "/tmp/seemless-test", directoryHint: .isDirectory))

    @Test func subdirectoriesFollowDocs02() {
        #expect(layout.images.path(percentEncoded: false) == "/tmp/seemless-test/images/")
        #expect(layout.vm().path(percentEncoded: false) == "/tmp/seemless-test/vms/default/")
        #expect(layout.cache.path(percentEncoded: false) == "/tmp/seemless-test/cache/")
        #expect(layout.runDirectory(pid: 42).path(percentEncoded: false) == "/tmp/seemless-test/run/42/")
    }

    @Test func defaultRootIsApplicationSupport() {
        #expect(StorageLayout.default.root.path(percentEncoded: false).hasSuffix("/Library/Application Support/Seemless/"))
    }

    @Test func socketPathLimit() {
        let short = layout.runDirectory(pid: 1).appending(path: "qmp.sock")
        #expect(StorageLayout.isValidSocketPath(short))

        let long = URL(filePath: "/" + String(repeating: "a", count: 200) + "/qmp.sock")
        #expect(!StorageLayout.isValidSocketPath(long))
    }

    /// The real default run directory must leave room for our socket names.
    /// If this fails on some user's machine, docs/02's layout must change.
    @Test func defaultRunDirectoryFitsSocketNames() {
        let sock = StorageLayout.default.runDirectory(pid: 99_999).appending(path: "display.sock")
        #expect(StorageLayout.isValidSocketPath(sock))
    }
}
