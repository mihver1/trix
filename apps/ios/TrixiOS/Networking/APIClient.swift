import Foundation

struct APIClient {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURLString: String, session: URLSession = .shared) throws {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let baseURL = URL(string: trimmed), baseURL.scheme != nil, baseURL.host != nil else {
            throw APIError.invalidBaseURL(trimmed)
        }

        self.baseURL = baseURL
        self.session = session

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = encoder
    }

    func get<Response: Decodable>(
        _ path: String,
        accessToken: String? = nil
    ) async throws -> Response {
        let request = try URLRequest(
            url: url(for: path),
            method: "GET",
            accessToken: accessToken
        )
        return try await perform(request)
    }

    func post<Request: Encodable, Response: Decodable>(
        _ path: String,
        body: Request,
        accessToken: String? = nil
    ) async throws -> Response {
        let bodyData: Data
        do {
            bodyData = try encoder.encode(body)
        } catch {
            throw APIError.encoding(error)
        }

        let request = try URLRequest(
            url: url(for: path),
            method: "POST",
            body: bodyData,
            accessToken: accessToken
        )
        return try await perform(request)
    }

    func put<Request: Encodable, Response: Decodable>(
        _ path: String,
        body: Request,
        accessToken: String? = nil
    ) async throws -> Response {
        let bodyData: Data
        do {
            bodyData = try encoder.encode(body)
        } catch {
            throw APIError.encoding(error)
        }

        let request = try URLRequest(
            url: url(for: path),
            method: "PUT",
            body: bodyData,
            accessToken: accessToken
        )
        return try await perform(request)
    }

    func delete(
        _ path: String,
        accessToken: String? = nil
    ) async throws {
        let request = try URLRequest(
            url: url(for: path),
            method: "DELETE",
            accessToken: accessToken
        )
        _ = try await performWithoutBody(request)
    }

    func baseURLString() throws -> String {
        baseURL.absoluteString.removingPercentEncoding ?? baseURL.absoluteString
    }

    private func url(for path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw APIError.invalidPath(path)
        }

        return url
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        do {
            let (data, response) = try await session.data(for: request)
            return try decode(Response.self, from: data, response: response)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(error)
        }
    }

    private func performWithoutBody(_ request: URLRequest) async throws -> VoidResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }

            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                let serverError = try? decoder.decode(APIErrorEnvelope.self, from: data)
                throw APIError.http(
                    statusCode: httpResponse.statusCode,
                    message: serverError?.message
                )
            }

            return VoidResponse()
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(error)
        }
    }

    private func decode<Response: Decodable>(
        _ type: Response.Type,
        from data: Data,
        response: URLResponse
    ) throws -> Response {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let serverError = try? decoder.decode(APIErrorEnvelope.self, from: data)
            throw APIError.http(statusCode: httpResponse.statusCode, message: serverError?.message)
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }
}

private struct APIErrorEnvelope: Decodable {
    let code: String
    let message: String
}

private struct VoidResponse: Decodable {
    init() {}

    init(from decoder: Decoder) throws {}
}

private extension URLRequest {
    init(url: URL, method: String, body: Data? = nil, accessToken: String? = nil) {
        self.init(url: url)
        httpMethod = method
        setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let accessToken {
            setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        httpBody = body
    }
}
