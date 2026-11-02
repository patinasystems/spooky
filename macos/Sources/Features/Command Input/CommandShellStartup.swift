import Foundation

/// Installs a private zsh entry point without replacing the configured command
/// or changing the user's startup files. The core supplies the resolved shell
/// environment and temporarily redirects ZDOTDIR to this directory.
enum CommandShellStartup {
    static func prepare(in directory: URL, bundle: Bundle = .main) throws {
        guard let adapter = bundle.url(forResource: "native-input", withExtension: "zsh") else {
            throw StartupError.missingResource("native-input.zsh")
        }
        guard let startup = bundle.url(forResource: "native-input-startup", withExtension: "zsh") else {
            throw StartupError.missingResource("native-input-startup.zsh")
        }
        try prepare(in: directory, adapter: adapter, startup: startup)
    }

    static func prepare(in directory: URL, adapter: URL, startup: URL) throws {
        // Read both resources before exposing an entry point. Copying their bytes
        // also keeps app-bundle paths out of shell source and shell quoting.
        let adapterData = try Data(contentsOf: adapter)
        let startupData = try Data(contentsOf: startup)
        try install(adapterData, at: directory.appendingPathComponent("native-input.zsh"))
        try install(startupData, at: directory.appendingPathComponent(".zshenv"))
    }

    private static func install(_ data: Data, at destination: URL) throws {
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    enum StartupError: LocalizedError {
        case missingResource(String)

        var errorDescription: String? {
            switch self {
            case .missingResource(let name):
                return "The \(name) app resource is missing."
            }
        }
    }
}
