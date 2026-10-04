import Foundation
import Observation

/// A git remote in a project folder, and the GitHub repo it points to, if any.
struct GitRemote: Hashable {
    var name: String
    var url: String
    /// "owner/name" when the remote is on GitHub.
    var repo: String?
}

/// What the project folder's git checkout looks like right now.
struct GitStatus: Equatable {
    var remotes: [GitRemote]
    var branch: String?
    /// Commits not yet pushed, and commits on the remote not yet pulled. nil without an upstream.
    var ahead: Int?
    var behind: Int?

    func remote(preferring name: String?) -> GitRemote? {
        let github = remotes.filter { $0.repo != nil }
        return github.first { $0.name == name } ?? github.first { $0.name == "origin" } ?? github.first
    }
}

/// Reads a pipe to its end on another thread, so it can drain while the caller reads a
/// different one.
final class PipeDrain: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ pipe: Pipe) {
        DispatchQueue.global(qos: .utility).async {
            self.data = pipe.fileHandleForReading.readDataToEndOfFile()
            self.done.signal()
        }
    }

    /// Everything the pipe carried, once the writer has closed it.
    func wait() -> Data {
        done.wait()
        return data
    }
}

/// Runs git and gh. Both come from the user's own install, so gh uses their existing sign-in.
enum Git {
    struct Output { var status: Int32; var out: String; var err: String }

    static func run(_ executable: String, _ args: [String], in folder: String? = nil) async -> Output {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            if let folder { process.currentDirectoryURL = URL(fileURLWithPath: folder) }
            process.environment = BinaryLocator.environment
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return Output(status: -1, out: "", err: error.localizedDescription) }
            // Read both pipes at once, and before waiting: a child that fills one pipe while
            // the other is being read to the end would otherwise stall forever.
            let errors = PipeDrain(err)
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = errors.wait()
            process.waitUntilExit()
            return Output(status: process.terminationStatus,
                          out: String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                          err: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }

    static func git(_ args: [String], in folder: String) async -> Output {
        await run("/usr/bin/git", args, in: folder)
    }

    /// nil when the folder isn't a git checkout.
    static func status(of folder: String) async -> GitStatus? {
        guard await git(["rev-parse", "--is-inside-work-tree"], in: folder).out == "true" else { return nil }
        var remotes: [GitRemote] = []
        for name in await git(["remote"], in: folder).out.split(separator: "\n").map(String.init) {
            let url = await git(["remote", "get-url", name], in: folder).out
            remotes.append(GitRemote(name: name, url: url, repo: githubRepo(from: url)))
        }
        let branch = await git(["rev-parse", "--abbrev-ref", "HEAD"], in: folder)
        let counts = await git(["rev-list", "--left-right", "--count", "@{upstream}...HEAD"], in: folder)
        let numbers = counts.status == 0 ? counts.out.split(whereSeparator: \.isWhitespace).compactMap { Int($0) } : []
        return GitStatus(remotes: remotes,
                         branch: branch.status == 0 && branch.out != "HEAD" ? branch.out : nil,
                         ahead: numbers.count == 2 ? numbers[1] : nil,
                         behind: numbers.count == 2 ? numbers[0] : nil)
    }

    /// "owner/name" from https, ssh, or scp-style GitHub URLs.
    static func githubRepo(from url: String) -> String? {
        let patterns = [#/^https?://(?:[^@/]+@)?github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$/#,
                        #/^ssh://git@github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$/#,
                        #/^git@github\.com:([^/]+)/([^/]+?)(?:\.git)?/?$/#]
        for pattern in patterns {
            if let match = url.firstMatch(of: pattern) { return "\(match.1)/\(match.2)" }
        }
        return nil
    }

    /// Accepts "owner/name" or any GitHub URL.
    static func parseRepo(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let repo = githubRepo(from: trimmed) { return repo }
        if trimmed.firstMatch(of: #/^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$/#) != nil { return trimmed }
        return nil
    }
}

/// One of the user's repos, as `gh repo list` reports it.
struct GitHubRepo: Identifiable, Hashable {
    var id: String { nameWithOwner }
    var nameWithOwner: String
    var description: String
    var isPrivate: Bool
    var updatedAt: Date?
}

enum GitHubCLI {
    static func locate() -> String? { BinaryLocator.find("gh", customPathKey: "ghPath") }

    /// The user's repos plus those of their organizations, most recently updated first.
    static func listRepos() async throws -> [GitHubRepo] {
        guard let gh = locate() else { throw ClaudeCodeError(message: "Couldn't find the GitHub CLI (`gh`). Install it, or paste a repo URL.") }
        var owners: [String?] = [nil]
        let orgs = await Git.run(gh, ["api", "user/orgs", "--jq", ".[].login"])
        if orgs.status == 0 { owners += orgs.out.split(separator: "\n").map { String($0) } }

        var repos: [String: GitHubRepo] = [:]
        let dates = ISO8601DateFormatter()
        for owner in owners {
            let args = ["repo", "list"] + (owner.map { [$0] } ?? []) + ["--limit", "200", "--json", "nameWithOwner,description,isPrivate,updatedAt"]
            let result = await Git.run(gh, args)
            guard result.status == 0 else {
                if owner == nil { throw ClaudeCodeError(message: result.err.isEmpty ? "`gh repo list` failed. Run `gh auth login` in Terminal." : result.err) }
                continue
            }
            for item in (try? JSON.parse(result.out))?.array ?? [] {
                guard let name = item["nameWithOwner"]?.string else { continue }
                repos[name] = GitHubRepo(nameWithOwner: name, description: item["description"]?.string ?? "",
                                         isPrivate: item["isPrivate"]?.bool ?? false,
                                         updatedAt: item["updatedAt"]?.string.flatMap(dates.date(from:)))
            }
        }
        return repos.values.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    static func clone(_ repo: String, into destination: String) async throws {
        guard let gh = locate() else { throw ClaudeCodeError(message: "Couldn't find the GitHub CLI (`gh`).") }
        let result = await Git.run(gh, ["repo", "clone", repo, destination])
        guard result.status == 0 else {
            throw ClaudeCodeError(message: result.err.isEmpty ? "Cloning \(repo) failed." : result.err)
        }
    }
}

/// Live git status for project folders, refreshed when a chat opens and after each turn.
@MainActor
@Observable
final class GitStatusStore {
    static let shared = GitStatusStore()

    private(set) var statuses: [String: GitStatus] = [:]
    private(set) var fetching: Set<String> = []

    func status(for folder: String?) -> GitStatus? { folder.flatMap { statuses[$0] } }

    /// Re-reads the checkout. With `fetch`, first asks the remote what's new.
    func refresh(_ folder: String, fetch: Bool = false) async {
        if fetch {
            fetching.insert(folder)
            _ = await Git.git(["fetch", "--quiet"], in: folder)
            fetching.remove(folder)
        }
        let status = await Git.status(of: folder)
        if statuses[folder] != status { statuses[folder] = status }
    }
}
