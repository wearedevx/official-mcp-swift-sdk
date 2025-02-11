import Foundation
import Logging

@testable import MCP

/// Mock transport for testing
actor MockTransport: Transport {
    var logger: Logger
    var isConnected = false
    private(set) var sentMessages: [String] = []
    private var messagesToReceive: [String] = []
    private var messageStreamContinuation: AsyncThrowingStream<String, Swift.Error>.Continuation?
    var shouldFailConnect = false
    var shouldFailSend = false

    init(logger: Logger = Logger(label: "mcp.test.transport")) {
        self.logger = logger
    }

    func connect() async throws {
        if shouldFailConnect {
            throw Error.transportError(POSIXError(.ECONNREFUSED))
        }
        isConnected = true
    }

    func disconnect() async {
        isConnected = false
        messageStreamContinuation?.finish()
        messageStreamContinuation = nil
    }

    func send<T: Encodable & Sendable>(_ message: T) async throws {
        if shouldFailSend {
            throw Error.transportError(POSIXError(.EIO))
        }
        let data = try JSONEncoder().encode(message)
        let str = String(data: data, encoding: .utf8)!
        sentMessages.append(str)
    }

    func receive() -> AsyncThrowingStream<String, Swift.Error> {
        return AsyncThrowingStream<String, Swift.Error> { continuation in
            messageStreamContinuation = continuation
            // Send any queued messages
            for message in messagesToReceive {
                continuation.yield(message)
            }
            messagesToReceive.removeAll()
        }
    }

    func queueRequest<M: MCP.Method>(_ request: Request<M>) throws {
        let data = try JSONEncoder().encode(request)
        let str = String(data: data, encoding: .utf8)!
        if let continuation = messageStreamContinuation {
            continuation.yield(str)
        } else {
            sentMessages.append(str)
        }
    }

    func queueResponse<M: MCP.Method>(_ response: Response<M>) throws {
        let data = try JSONEncoder().encode(response)
        let str = String(data: data, encoding: .utf8)!
        if let continuation = messageStreamContinuation {
            continuation.yield(str)
        } else {
            messagesToReceive.append(str)
        }
    }

    func queueNotification<N: MCP.Notification>(_ notification: Message<N>) throws {
        let data = try JSONEncoder().encode(notification)
        let str = String(data: data, encoding: .utf8)!
        if let continuation = messageStreamContinuation {
            continuation.yield(str)
        } else {
            messagesToReceive.append(str)
        }
    }

    func getLastSentMessage<T: Decodable>() -> T? {
        print("SENT:", sentMessages)
        guard let lastMessage = sentMessages.last else { return nil }
        do {
            let data = lastMessage.data(using: .utf8)!
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    func clearMessages() {
        sentMessages.removeAll()
        messagesToReceive.removeAll()
    }

    func setFailConnect(_ shouldFail: Bool) {
        shouldFailConnect = shouldFail
    }

    func setFailSend(_ shouldFail: Bool) {
        shouldFailSend = shouldFail
    }
}
