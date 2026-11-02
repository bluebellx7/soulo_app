import CoreFoundation
import Foundation

struct ED2KFileLink: Equatable {
    let name: String
    let size: Int64
    let hash: String
    var sources: [String] = []
    var url: URL {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "Download"
        // eD2K's pipe-separated authority is not an RFC URL host. Preserve it
        // losslessly in an opaque URL for Foundation and the persisted ledger.
        let peers = sources.isEmpty ? "" : "|sources," + sources.joined(separator: ",")
        let payload = "//|file|\(encoded)|\(size)|\(hash)\(peers)|/"
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        return URL(string: "ed2k:" + payload)!
    }
}

enum PeerDownloadLink: Equatable {
    case web(URL), magnet(URL), ed2k(ED2KFileLink)

    static func parse(_ input: String) throws -> Self {
        let value = try unwrap(input.trimmingCharacters(in: .whitespacesAndNewlines))
        if value.lowercased().hasPrefix("ed2k:") {
            var raw = value
            // Foundation may escape the separators when receiving an openURL.
            if !raw.contains("|"), let decoded = raw.removingPercentEncoding { raw = decoded }
            let parts = raw.components(separatedBy: "|")
            guard parts.count >= 6, parts[0].lowercased() == "ed2k://", parts[1].lowercased() == "file",
                  parts.last == "/", let size = Int64(parts[3]), size > 0, size <= 1 << 44,
                  parts[4].utf8.count == 32, parts[4].utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  let name = parts[2].removingPercentEncoding, !name.isEmpty,
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw TorrentTaskError.invalid }
            let sources = parts.dropFirst(5).filter { $0.hasPrefix("sources,") }
                .flatMap { $0.dropFirst(8).split(separator: ",").map(String.init) }
            guard sources.count <= 32, sources.allSatisfy({ $0.utf8.count <= 256 }) else { throw TorrentTaskError.invalid }
            return .ed2k(ED2KFileLink(name: name, size: size, hash: parts[4].uppercased(), sources: sources))
        }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { throw TorrentTaskError.invalid }
        if scheme == "magnet" { return .magnet(url) }
        guard ["http", "https"].contains(scheme), url.host?.isEmpty == false, url.user == nil, url.password == nil else {
            throw TorrentTaskError.invalid
        }
        return .web(url)
    }

    private static func unwrap(_ input: String) throws -> String {
        guard input.utf8.count <= 65536 else { throw TorrentTaskError.invalid }
        guard input.lowercased().hasPrefix("thunder://") else { return input }
        var encoded = String(input.dropFirst(10))
        if encoded.hasSuffix("/") { encoded.removeLast() }
        encoded = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), data.count <= 49152 else { throw TorrentTaskError.invalid }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        guard let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: gb18030),
              decoded.hasPrefix("AA"), decoded.hasSuffix("ZZ") else { throw TorrentTaskError.invalid }
        let target = String(decoded.dropFirst(2).dropLast(2))
        guard !target.lowercased().hasPrefix("thunder:") else { throw TorrentTaskError.invalid }
        return target
    }
}
