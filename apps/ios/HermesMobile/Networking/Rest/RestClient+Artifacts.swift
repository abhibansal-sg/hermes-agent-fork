import Foundation

// MARK: - Stock media and legacy attachment reads

extension RestClient {
    /// `GET /api/media?path=…` — stock Hermes authenticated media read for an
    /// image previously materialized by `image.attach_bytes` or another gateway
    /// tool. The server confines reads to its own image/screenshot/cache roots.
    func mediaData(path: String) async throws -> Data {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        let query = components.percentEncodedQuery ?? ""
        let data = try await get(path: "/api/media?\(query)")
        struct Response: Decodable { let dataUrl: String }
        let response = try decode(Response.self, from: data, context: "media")
        guard let comma = response.dataUrl.firstIndex(of: ","),
              response.dataUrl[..<comma].lowercased().hasPrefix("data:image/"),
              response.dataUrl[..<comma].lowercased().contains(";base64") else {
            throw RestError.decoding("media: expected an image data URL")
        }
        let encoded = String(response.dataUrl[response.dataUrl.index(after: comma)...])
        guard let decoded = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              !decoded.isEmpty else {
            throw RestError.decoding("media: invalid base64 image payload")
        }
        return decoded
    }

    /// Read-only compatibility shim for legacy plugin-uploaded images whose
    /// persisted paths are outside stock `/api/media` roots. No new writes use
    /// this endpoint; it can be removed after the supported-client migration window.
    func attachmentData(name: String) async throws -> Data {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return try await get(
            path: "/api/plugins/hermes-mobile/attachments/\(encodedName)"
        )
    }

}
