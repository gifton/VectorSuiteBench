import Foundation

/// Git provenance captured at run start. Probes `git` via Process; failures
/// are silent (a sandboxed app may not have git available — fields just say
/// "unknown" and the run still proceeds).
public struct GitProvenance: Codable, Hashable, Sendable {
    public let sha: String
    public let branch: String
    public let dirty: Bool

    public init(sha: String, branch: String, dirty: Bool) {
        self.sha = sha
        self.branch = branch
        self.dirty = dirty
    }

    public static func probe(workingDirectory: URL? = nil) -> GitProvenance {
        let cwd = workingDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sha = runGit(["rev-parse", "--short", "HEAD"], in: cwd) ?? "unknown"
        let branch = runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: cwd) ?? "unknown"
        let dirtyStr = runGit(["status", "--porcelain"], in: cwd) ?? ""
        return GitProvenance(sha: sha, branch: branch, dirty: !dirtyStr.isEmpty)
    }

    private static func runGit(_ args: [String], in dir: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = dir
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()  // discard stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
