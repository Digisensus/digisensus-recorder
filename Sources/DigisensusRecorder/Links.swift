import Foundation

extension URL {
    static func link(scheme: String = "https", host: String, path: String, query: KeyValuePairs<String, String>) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}
