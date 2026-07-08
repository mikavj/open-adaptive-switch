// Open Adaptive Switch - firmware release lookup against GitHub.
//
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Open Adaptive Switch contributors

import Foundation

struct FirmwareRelease {
    var version: String        // "3.0.0", tag with the leading v stripped
    var zipName: String
    var zipURL: URL
    var notes: String?
}

enum ReleaseChecker {
    static let repo = "mikavj/open-adaptive-switch"

    enum CheckError: LocalizedError {
        case noReleases
        case badResponse(Int)
        case noPackage

        var errorDescription: String? {
            switch self {
            case .noReleases: return "No firmware releases have been published yet."
            case .badResponse(let code): return "Couldn't check right now (GitHub said \(code))."
            case .noPackage: return "The latest release has no update package attached."
            }
        }
    }

    static func latest() async throws -> FirmwareRelease {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw CheckError.badResponse(0) }
        if http.statusCode == 404 { throw CheckError.noReleases }
        guard http.statusCode == 200 else { throw CheckError.badResponse(http.statusCode) }

        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        struct Release: Decodable {
            let tag_name: String
            let body: String?
            let assets: [Asset]
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard let zip = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            throw CheckError.noPackage
        }
        var version = release.tag_name
        if version.lowercased().hasPrefix("v") { version.removeFirst() }
        return FirmwareRelease(version: version, zipName: zip.name,
                               zipURL: zip.browser_download_url, notes: release.body)
    }

    // Download the update package to a local file the DFU library can read.
    static func download(_ release: FirmwareRelease) async throws -> URL {
        let (temp, response) = try await URLSession.shared.download(from: release.zipURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CheckError.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(release.zipName)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    // Positive when a is newer than b. Dotted numeric compare on the part
    // before any prerelease suffix ("3.1.0-beta" compares as 3.1.0).
    static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] {
            let core = s.split(separator: "-").first.map(String.init) ?? s
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let d = (i < pa.count ? pa[i] : 0) - (i < pb.count ? pb[i] : 0)
            if d != 0 { return d }
        }
        return 0
    }
}
