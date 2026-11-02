import Foundation
import Testing
@testable import Ghostty

struct CommandShellStartupTests {
    @Test func installsExactResourcesWithPrivatePermissions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("app's resources", isDirectory: true)
        let destination = root.appendingPathComponent("pane", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let adapter = resources.appendingPathComponent("native-input.zsh")
        let startup = resources.appendingPathComponent("native-input-startup.zsh")
        let adapterData = Data("# fixture adapter\nprint -r -- '$not-expanded'\n".utf8)
        let startupData = Data("# fixture entry point\nprint -r -- '$(not executed)'\n".utf8)
        try adapterData.write(to: adapter)
        try startupData.write(to: startup)

        try CommandShellStartup.prepare(in: destination, adapter: adapter, startup: startup)

        let installedAdapter = destination.appendingPathComponent("native-input.zsh")
        let installedStartup = destination.appendingPathComponent(".zshenv")
        #expect(try Data(contentsOf: installedAdapter) == adapterData)
        #expect(try Data(contentsOf: installedStartup) == startupData)
        for file in [installedAdapter, installedStartup] {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(Set(names) == Set(["native-input.zsh", ".zshenv"]))
    }

    @Test func missingResourceDoesNotInstallAnEntryPoint() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = root.appendingPathComponent("adapter-source.zsh")
        try Data("# fixture\n".utf8).write(to: adapter)

        #expect(throws: (any Error).self) {
            try CommandShellStartup.prepare(in: root, adapter: adapter,
                                            startup: root.appendingPathComponent("missing.zsh"))
        }

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".zshenv").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("native-input.zsh").path))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("command-shell-startup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return url
    }
}
