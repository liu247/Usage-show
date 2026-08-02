import Foundation

enum APIClient {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        return URLSession(configuration: cfg)
    }()

    /// GET 请求，返回原始 Data；非 2xx 抛 HTTPError
    static func get(_ url: URL, headers: [String: String]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw HTTPError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPError.status(http.statusCode)
        }
        return data
    }
}

enum HTTPError: Error {
    case badResponse
    case status(Int)
}
