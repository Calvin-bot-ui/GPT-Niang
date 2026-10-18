import Foundation
import CryptoKit

public struct UpdateFailure: LocalizedError {
    public let message: String
    public let retryAfter: TimeInterval?
    public init(_ message: String, retryAfter: TimeInterval? = nil) { self.message = message; self.retryAfter = retryAfter }
    public var errorDescription: String? { message }
}

public struct StableVersion: Comparable, Equatable {
    public let value: String
    private let parts: [String]
    public init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { 48...57 ~= $0 } && ($0 == "0" || !$0.hasPrefix("0")) }) else { return nil }
        self.value = value; self.parts = parts
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        for (a, b) in zip(lhs.parts, rhs.parts) where a != b { return a.count == b.count ? a < b : a.count < b.count }
        return false
    }
}

public struct ReleaseAsset: Decodable {
    public let name: String
    public let browser_download_url: URL
    public let size: Int
    public let digest: String?
}
public struct OfficialRelease: Decodable {
    public let tag_name: String
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [ReleaseAsset]
}
public struct SelectedRelease {
    public let version: String
    public let archive: ReleaseAsset
    public let checksums: ReleaseAsset
}
public enum UpdatePolicy {
    public static let bundleID = "io.github.t7moris.GPTNiangMac"
    public static let api = URL(string: "https://api.github.com/repos/Calvin-bot-ui/GPT-Niang/releases/latest")!
    public static let maximumArchive = 50 * 1024 * 1024
    public static let maximumExpanded = 200 * 1024 * 1024
    public static let day: TimeInterval = 86400
    private static let releasePath = "/Calvin-bot-ui/GPT-Niang/releases/download/"
    public static func allowed(_ url: URL, apiOnly: Bool = false) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil, url.fragment == nil else { return false }
        if apiOnly { return url == api }
        return (url.host == "github.com" && url.path.hasPrefix(releasePath)) ||
            ["release-assets.githubusercontent.com", "github-releases.githubusercontent.com"].contains(url.host ?? "")
    }
    public static func select(_ release: OfficialRelease, current: String) throws -> SelectedRelease? {
        guard !release.draft, !release.prerelease, let version = StableVersion(release.tag_name),
              let installed = StableVersion(current), version > installed else { return nil }
        func asset(_ name: String) throws -> ReleaseAsset {
            let found = release.assets.filter { $0.name == name }
            guard found.count == 1, let value = found.first, allowed(value.browser_download_url),
                  value.browser_download_url.host == "github.com",
                  value.browser_download_url.path == releasePath + release.tag_name + "/" + name,
                  value.size > 0, value.size <= maximumArchive else { throw UpdateFailure("正式版下載檔案不完整。") }
            return value
        }
        return try SelectedRelease(version: version.value,
            archive: asset("gpt-niang-usage-widget-v\(version.value)-macos-universal.zip"), checksums: asset("SHA256SUMS.txt"))
    }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func verify(_ data: Data, asset: ReleaseAsset) throws {
        guard data.count == asset.size, asset.digest == nil || asset.digest?.lowercased() == "sha256:" + hash(data) else {
            throw UpdateFailure("下載大小或 GitHub 校驗值不符。")
        }
    }
    public static func verifyArchive(_ data: Data, checksums: Data, asset: ReleaseAsset) throws -> String {
        try verify(data, asset: asset)
        guard let text = String(data: checksums, encoding: .utf8) else { throw UpdateFailure("校驗檔案無法讀取。") }
        let rows = text.components(separatedBy: .newlines).filter { line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }); return fields.count == 2 && fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == asset.name
        }
        guard rows.count == 1, let expected = rows.first?.split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
              expected.count == 64, expected.lowercased() == hash(data) else { throw UpdateFailure("更新包 SHA256 校驗失敗。") }
        return hash(data)
    }
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    let apiOnly: Bool
    init(apiOnly: Bool) { self.apiOnly = apiOnly }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(!apiOnly && request.url.map { UpdatePolicy.allowed($0) } == true ? request : nil)
    }
}
public enum NativeDownload {
    public static func bytes(from url: URL, limit: Int) async throws -> Data {
        guard UpdatePolicy.allowed(url, apiOnly: url == UpdatePolicy.api) else { throw UpdateFailure("更新來源不可信。") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration, delegate: RedirectGuard(apiOnly: url == UpdatePolicy.api), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.setValue("GPTNiangMac-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue(url == UpdatePolicy.api ? "application/vnd.github+json" : "application/octet-stream", forHTTPHeaderField: "Accept")
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw UpdateFailure("更新伺服器回應無效。") }
        guard response.statusCode == 200 else {
            let retry = TimeInterval(response.value(forHTTPHeaderField: "Retry-After") ?? "")
            throw UpdateFailure("更新檢查暫時無法完成（\(response.statusCode)）。", retryAfter: retry)
        }
        guard response.expectedContentLength <= Int64(limit) else { throw UpdateFailure("更新檔案超過大小限制。") }
        var result = Data()
        for try await byte in stream {
            guard result.count < limit else { throw UpdateFailure("更新檔案超過大小限制。") }
            result.append(byte)
            if result.count % 8192 == 0 { try Task.checkCancellation() }
        }
        return result
    }
}
