import Foundation

/// Telefon sayfasının ihtiyacı kadar HTTP/1.1: tek istek, tek yanıt, bağlantı kapanır.
/// Keep-alive ve chunked gövde yok; tarayıcılar ve HTTP Shortcuts bunlarsız çalışıyor.
struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    /// Anahtarlar küçük harfli.
    let headers: [String: String]
    let body: Data

    enum ParseResult {
        case complete(HTTPRequest)
        case incomplete
        case invalid
    }

    static func parse(_ data: Data) -> ParseResult {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid
        }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard
            requestLine.count == 3,
            requestLine[2].hasPrefix("HTTP/1."),
            let target = URLComponents(string: String(requestLine[1]))
        else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { return .invalid }

        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid }
        let bodyStart = headerEnd.upperBound
        guard data.endIndex - bodyStart >= length else { return .incomplete }

        var query: [String: String] = [:]
        for item in target.queryItems ?? [] { query[item.name] = item.value }

        return .complete(HTTPRequest(
            method: String(requestLine[0]),
            path: target.path,
            query: query,
            headers: headers,
            body: Data(data[bodyStart..<bodyStart + length])
        ))
    }
}

struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data
    var cacheControl = "no-store"
    var extraHeaders: [(String, String)] = []

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        HTTPResponse(
            status: status,
            contentType: "application/json; charset=utf-8",
            body: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        )
    }

    static func error(_ message: String, status: Int) -> HTTPResponse {
        json(["error": message], status: status)
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: \(cacheControl)\r\n"
        head += "Connection: close\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        // Sayfanın adresinde anahtar var; hiçbir yere Referer olarak sızmasın.
        head += "Referrer-Policy: no-referrer\r\n"
        for (name, value) in extraHeaders { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        default: return "Error"
        }
    }
}
