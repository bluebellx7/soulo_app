import Foundation
import Security
import CryptoKit
import Darwin

/// Display-only parsing. Trust decisions remain entirely with WebKit and iOS.
struct SiteCertificateInfo: Identifiable, Sendable {
    let id: String
    let subject: String
    let issuer: String
    let serial: String
    let notBefore: Date?
    let notAfter: Date?
    let domains: [String]
    let publicKey: String
    let fingerprint: String

    init?(data: Data) {
        guard data.count <= 1_048_576, let certificate = SecCertificateCreateWithData(nil, data as CFData),
              let root = try? DER.nodes(data).first, root.tag == 0x30,
              let fields = try? DER.nodes(root.value), let tbs = fields.first,
              let values = try? DER.nodes(tbs.value) else { return nil }
        let start = values.first?.tag == 0xa0 ? 1 : 0
        guard values.count >= start + 6 else { return nil }
        let digest = SHA256.hash(data: data)
        id = digest.map { String(format: "%02X", $0) }.joined()
        fingerprint = digest.map { String(format: "%02X", $0) }.joined(separator: ":")
        subject = Self.name(values[start + 4].value)
            ?? (SecCertificateCopySubjectSummary(certificate) as String?) ?? "—"
        issuer = Self.name(values[start + 2].value) ?? "—"
        serial = values[start].value.map { String(format: "%02X", $0) }.joined(separator: ":")
        let validity = (try? DER.nodes(values[start + 3].value)) ?? []
        notBefore = validity.first.flatMap(Self.date)
        notAfter = validity.dropFirst().first.flatMap(Self.date)
        var names: [String] = []
        if let extensions = values.dropFirst(start + 6).first(where: { $0.tag == 0xa3 }),
           let sequence = try? DER.nodes(extensions.value).first,
           let entries = try? DER.nodes(sequence.value) {
            for entry in entries {
                guard let parts = try? DER.nodes(entry.value), parts.first?.value == Data([0x55, 0x1d, 0x11]),
                      let octet = parts.last, octet.tag == 0x04,
                      let sequence = try? DER.nodes(octet.value).first,
                      let alternatives = try? DER.nodes(sequence.value) else { continue }
                for alternative in alternatives.prefix(1000) {
                    if alternative.tag == 0x82, let dns = String(data: alternative.value, encoding: .utf8) { names.append(dns) }
                    if alternative.tag == 0x87, let ip = Self.ipAddress(alternative.value) { names.append(ip) }
                }
            }
        }
        domains = names
        if let key = SecCertificateCopyKey(certificate), let attributes = SecKeyCopyAttributes(key) as? [String: Any] {
            let type = attributes[kSecAttrKeyType as String] as? String
            let algorithm = type == (kSecAttrKeyTypeRSA as String) ? "RSA" : type == (kSecAttrKeyTypeECSECPrimeRandom as String) ? "EC" : "—"
            let bits = attributes[kSecAttrKeySizeInBits as String] as? Int
            publicKey = algorithm + (bits.map { " · \($0) bit" } ?? "")
        } else { publicKey = "—" }
    }

    static func chain(from trust: SecTrust?) -> [SiteCertificateInfo] {
        guard let trust, let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else { return [] }
        return certificates.prefix(16).compactMap { SiteCertificateInfo(data: SecCertificateCopyData($0) as Data) }
    }

    private static func name(_ data: Data) -> String? {
        let labels: [Data: String] = [Data([0x55,0x04,0x03]): "CN", Data([0x55,0x04,0x06]): "C",
            Data([0x55,0x04,0x07]): "L", Data([0x55,0x04,0x08]): "ST",
            Data([0x55,0x04,0x0a]): "O", Data([0x55,0x04,0x0b]): "OU"]
        guard let sets = try? DER.nodes(data) else { return nil }
        var result: [String] = []
        for set in sets {
            for pair in (try? DER.nodes(set.value)) ?? [] {
                guard let fields = try? DER.nodes(pair.value), fields.count == 2,
                      let name = String(data: fields[1].value, encoding: fields[1].tag == 0x1e ? .utf16BigEndian : .utf8) else { continue }
                result.append((labels[fields[0].value].map { $0 + "=" } ?? "") + name)
            }
        }
        return result.isEmpty ? nil : result.joined(separator: ", ")
    }

    private static func date(_ node: DER) -> Date? {
        guard [0x17, 0x18].contains(node.tag), var value = String(data: node.value, encoding: .ascii) else { return nil }
        if node.tag == 0x17 {
            guard value.count == 13, let year = Int(value.prefix(2)) else { return nil }
            value = (year >= 50 ? "19" : "20") + value
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        formatter.isLenient = false
        return formatter.date(from: value)
    }

    private static func ipAddress(_ data: Data) -> String? {
        guard data.count == 4 || data.count == 16 else { return nil }
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        return data.withUnsafeBytes { bytes in
            guard inet_ntop(data.count == 4 ? AF_INET : AF_INET6, bytes.baseAddress, &output, socklen_t(output.count)) != nil else { return nil }
            return String(cString: output)
        }
    }
}

private struct DER {
    let tag: UInt8
    let value: Data
    enum Failure: Error { case invalid }
    static func nodes(_ data: Data) throws -> [DER] {
        let bytes = [UInt8](data)
        var offset = 0
        var result: [DER] = []
        while offset < bytes.count {
            guard bytes.count - offset >= 2 else { throw Failure.invalid }
            let tag = bytes[offset]; offset += 1
            var length = Int(bytes[offset]); offset += 1
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard count > 0, count <= 4, count <= bytes.count - offset else { throw Failure.invalid }
                length = 0
                for _ in 0..<count { length = length * 256 + Int(bytes[offset]); offset += 1 }
            }
            guard length <= bytes.count - offset else { throw Failure.invalid }
            result.append(.init(tag: tag, value: Data(bytes[offset..<(offset + length)])))
            offset += length
        }
        return result
    }
}
