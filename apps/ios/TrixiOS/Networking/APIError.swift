import Foundation

enum APIError: LocalizedError {
    case invalidBaseURL(String)
    case invalidPath(String)
    case invalidResponse
    case encoding(Error)
    case http(statusCode: Int, message: String?)
    case transport(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case let .invalidBaseURL(value):
            return "Invalid server URL: \(value)"
        case let .invalidPath(path):
            return "Invalid API path: \(path)"
        case .invalidResponse:
            return "The server returned an invalid response."
        case let .encoding(error):
            return "Failed to encode request body: \(error.localizedDescription)"
        case let .http(statusCode, message):
            if let message, !message.isEmpty {
                return "Request failed with status \(statusCode): \(message)"
            }

            return "Request failed with status \(statusCode)."
        case let .transport(error):
            return error.localizedDescription
        case let .decoding(error):
            return "Failed to decode server response: \(error.localizedDescription)"
        }
    }
}
