import Foundation

extension String {
    var isValidURL: Bool {
        if let url = URL(string: self), url.scheme != nil, url.host != nil {
            return true
        }
        let pattern = #"^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+(/.*)?$"#
        return range(of: pattern, options: .regularExpression) != nil
    }

    var percentEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }

    func asSearchURL(template: String) -> URL? {
        let urlString = template.replacingOccurrences(of: "%@", with: percentEncoded)
        return URL(string: urlString)
    }

    var asURL: URL? {
        if let url = URL(string: self), url.scheme != nil {
            return url
        }
        if isValidURL {
            return URL(string: "https://\(self)")
        }
        return nil
    }
}
