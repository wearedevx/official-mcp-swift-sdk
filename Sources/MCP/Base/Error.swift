import Foundation

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

/// A model context protocol error.
public enum MCPError: Swift.Error, Sendable {
    // Standard JSON-RPC 2.0 errors (-32700 to -32603)
    case parseError(String?) // -32700
    case invalidRequest(String?) // -32600
    case methodNotFound(String?) // -32601
    case invalidParams(String?) // -32602
    case internalError(String?) // -32603
    // Server errors (-32000 to -32099)
    case serverError(code: Int, message: String)

    // Transport specific errors
    case connectionClosed
    case transportError(Swift.Error)
    case unauthorized(String?) // WWW-Authenticate header value
    case unsupportedMethod

    /// The JSON-RPC 2.0 error code
    public var code: Int {
        switch self {
        case .parseError: return -32700
        case .invalidRequest: return -32600
        case .methodNotFound: return -32601
        case .invalidParams: return -32602
        case .internalError: return -32603
        case let .serverError(code, _): return code
        case .connectionClosed: return -32000
        case .transportError: return -32001
        case .unauthorized: return -32002
        case .unsupportedMethod: return -32003
        }
    }

    /// Check if an error represents a "resource temporarily unavailable" condition
    public static func isResourceTemporarilyUnavailable(_ error: Swift.Error) -> Bool {
        #if canImport(System)
            if let errno = error as? System.Errno, errno == .resourceTemporarilyUnavailable {
                return true
            }
        #else
            if let errno = error as? SystemPackage.Errno, errno == .resourceTemporarilyUnavailable {
                return true
            }
        #endif
        return false
    }
}

// MARK: LocalizedError

extension MCPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .parseError(detail):
            return "Parse error: Invalid JSON" + (detail.map { ": \($0)" } ?? "")
        case let .invalidRequest(detail):
            return "Invalid Request" + (detail.map { ": \($0)" } ?? "")
        case let .methodNotFound(detail):
            return "Method not found" + (detail.map { ": \($0)" } ?? "")
        case let .invalidParams(detail):
            return "Invalid params" + (detail.map { ": \($0)" } ?? "")
        case let .internalError(detail):
            return "Internal error" + (detail.map { ": \($0)" } ?? "")
        case let .serverError(_, message):
            return "Server error: \(message)"
        case .connectionClosed:
            return "Connection closed"
        case let .transportError(error):
            return "Transport error: \(error.localizedDescription)"
        case .unauthorized:
            return "Unauthorized"
        case .unsupportedMethod:
            return "Unsupported method"
        }
    }

    public var failureReason: String? {
        switch self {
        case .parseError:
            return "The server received invalid JSON that could not be parsed"
        case .invalidRequest:
            return "The JSON sent is not a valid Request object"
        case .methodNotFound:
            return "The method does not exist or is not available"
        case .invalidParams:
            return "Invalid method parameter(s)"
        case .internalError:
            return "Internal JSON-RPC error"
        case .serverError:
            return "Server-defined error occurred"
        case .connectionClosed:
            return "The connection to the server was closed"
        case let .transportError(error):
            return (error as? LocalizedError)?.failureReason ?? error.localizedDescription
        case .unauthorized:
            return "Unauthorized"
        case .unsupportedMethod:
            return "Unsupported method"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .parseError:
            return "Verify that the JSON being sent is valid and well-formed"
        case .invalidRequest:
            return "Ensure the request follows the JSON-RPC 2.0 specification format"
        case .methodNotFound:
            return "Check the method name and ensure it is supported by the server"
        case .invalidParams:
            return "Verify the parameters match the method's expected parameters"
        case .connectionClosed:
            return "Try reconnecting to the server"
        default:
            return nil
        }
    }
}

// MARK: CustomDebugStringConvertible

extension MCPError: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case let .transportError(error):
            return
                "[\(code)] \(errorDescription ?? "") (Underlying error: \(String(reflecting: error)))"
        default:
            return "[\(code)] \(errorDescription ?? "")"
        }
    }
}

// MARK: Codable

extension MCPError: Codable {
    private enum CodingKeys: String, CodingKey {
        case code, message, data
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(errorDescription ?? "Unknown error", forKey: .message)

        // Encode additional data if available
        switch self {
        case let .parseError(detail),
             let .invalidRequest(detail),
             let .methodNotFound(detail),
             let .invalidParams(detail),
             let .internalError(detail):
            if let detail = detail {
                try container.encode(["detail": detail], forKey: .data)
            }
        case .serverError, .unauthorized, .unsupportedMethod:
            // No additional data for server errors
            break
        case .connectionClosed:
            break
        case let .transportError(error):
            try container.encode(
                ["error": error.localizedDescription],
                forKey: .data
            )
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(Int.self, forKey: .code)
        let message = try container.decode(String.self, forKey: .message)
        let data = try container.decodeIfPresent([String: Value].self, forKey: .data)

        // Helper to extract detail from data, falling back to message if needed
        let unwrapDetail: (String?) -> String? = { fallback in
            guard let detailValue = data?["detail"] else { return fallback }
            if case let .string(str) = detailValue { return str }
            return fallback
        }

        switch code {
        case -32700:
            self = .parseError(unwrapDetail(message))
        case -32600:
            self = .invalidRequest(unwrapDetail(message))
        case -32601:
            self = .methodNotFound(unwrapDetail(message))
        case -32602:
            self = .invalidParams(unwrapDetail(message))
        case -32603:
            self = .internalError(unwrapDetail(nil))
        case -32000:
            self = .connectionClosed
        case -32001:
            // Extract underlying error string if present
            let underlyingErrorString =
                data?["error"].flatMap { val -> String? in
                    if case let .string(str) = val { return str }
                    return nil
                } ?? message
            self = .transportError(
                NSError(
                    domain: "org.jsonrpc.error",
                    code: code,
                    userInfo: [NSLocalizedDescriptionKey: underlyingErrorString]
                )
            )
        default:
            self = .serverError(code: code, message: message)
        }
    }
}

// MARK: Equatable

extension MCPError: Equatable {
    public static func == (lhs: MCPError, rhs: MCPError) -> Bool {
        lhs.code == rhs.code
    }
}

// MARK: Hashable

extension MCPError: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(code)
        switch self {
        case let .parseError(detail):
            hasher.combine(detail)
        case let .invalidRequest(detail):
            hasher.combine(detail)
        case let .methodNotFound(detail):
            hasher.combine(detail)
        case let .invalidParams(detail):
            hasher.combine(detail)
        case let .internalError(detail):
            hasher.combine(detail)
        case let .serverError(_, message):
            hasher.combine(message)
        case .connectionClosed, .unauthorized, .unsupportedMethod:
            break
        case let .transportError(error):
            hasher.combine(error.localizedDescription)
        }
    }
}

// MARK: -

/// This is provided to allow existing code that uses `MCP.Error` to continue
/// to work without modification.
///
/// The MCPError type is now the recommended way to handle errors in MCP.
@available(*, deprecated, renamed: "MCPError", message: "Use MCPError instead of MCP.Error")
public typealias Error = MCPError
