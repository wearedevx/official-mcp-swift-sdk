import Foundation
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public actor HTTPClientTransport: Actor, Transport {
    struct SSERetryPolicy: Sendable {
        var maxAttempts: Int = 5
        var initialDelay: TimeInterval = 1
        var maxDelay: TimeInterval = 30
    }

    private struct RetryableSSEError: Swift.Error {
        let statusCode: Int
        let retryAfter: TimeInterval?
    }

    public var endpoint: URL
    public var endpointPostURL: URL?
    private let session: URLSession
    public private(set) var sessionID: String?
    private let streaming: Bool
    private var streamingTask: Task<Void, Never>?
    private var lastEventID: String?
    public nonisolated let logger: Logger
    public var endpointCommunication: URL?
    private var isConnected = false
    private var isListeningForServerEvents = false
    private var eventListeningError: MCPError?
    private var messageStream: AsyncThrowingStream<Data, Swift.Error>
    private var messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private let retryPolicy: SSERetryPolicy

    private let requestModifier: (@Sendable (URLRequest) async -> URLRequest)?

    public init(
        endpoint: URL,
        configuration: URLSessionConfiguration = .default,
        streaming: Bool = false,
        requestModifier: (@Sendable (URLRequest) async -> URLRequest)? = nil,
        logger: Logger? = nil,
        endpointCommunication: URL? = nil
    ) {
        self.init(
            endpoint: endpoint,
            session: URLSession(configuration: configuration),
            streaming: streaming,
            requestModifier: requestModifier,
            logger: logger,
            endpointCommunication: endpointCommunication
        )
    }

    init(
        endpoint: URL,
        session: URLSession,
        streaming: Bool = false,
        requestModifier: (@Sendable (URLRequest) async -> URLRequest)? = nil,
        logger: Logger? = nil,
        endpointCommunication: URL? = nil,
        retryPolicy: SSERetryPolicy = SSERetryPolicy()
    ) {
        self.endpoint = endpoint
        self.session = session
        self.streaming = streaming
        self.requestModifier = requestModifier
        self.retryPolicy = retryPolicy

        // Create message stream
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        messageStream = AsyncThrowingStream { continuation = $0 }
        messageContinuation = continuation

        self.logger =
            logger
                ?? Logger(
                    label: "mcp.transport.http.client",
                    factory: { _ in SwiftLogNoOpLogHandler() }
                )
        self.endpointCommunication = endpointCommunication
    }

    /// Establishes connection with the transport
    public func connect() async throws {
        guard !isConnected else { return }
        isConnected = true

        guard streaming else {
            logger.info("HTTP transport connected")
            return
        }

        eventListeningError = nil

        // Start listening to server events
        streamingTask = Task { await startListeningForServerEvents() }

        // wait for the connection to happen with a valid endpoint
        let timeoutNs = 45_000_000_000 // 45 seconds
        let sleepIntervalNs: UInt64 = 50_000_000 // 50 ms
        var elapsedNs: UInt64 = 0

        while !isListeningForServerEvents, eventListeningError == nil {
            if elapsedNs >= timeoutNs {
                throw MCPError.internalError("Timeout waiting for valid endpoint from SSE")
            }
            try await Task.sleep(nanoseconds: sleepIntervalNs)
            elapsedNs += sleepIntervalNs
        }

        if let eventListeningError {
            logger.warning(
                "HTTP transport failed to connect: \(eventListeningError.localizedDescription)"
            )
            isConnected = false
            streamingTask?.cancel()
            await streamingTask?.value
            streamingTask = nil
            throw eventListeningError
        }

        logger.info("HTTP transport connected")
    }

    /// Disconnects from the transport
    public func disconnect() async {
        guard isConnected else { return }
        isConnected = false

        // Cancel streaming task if active
        streamingTask?.cancel()
        await streamingTask?.value
        streamingTask = nil

        // Finish outstanding tasks and invalidate the session
        session.finishTasksAndInvalidate()

        // Clean up message stream
        messageContinuation.finish()

        logger.info("HTTP clienttransport disconnected")
    }

    /// Sends data through an HTTP POST request
    public func send(_ data: Data) async throws {
        guard isConnected else {
            throw MCPError.internalError("Transport not connected")
        }

        var request = URLRequest(url: endpointPostURL ?? endpoint)
        request.httpMethod = "POST"
        request.addValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        request.httpBody = data

        // Add session ID if available
        if let sessionID {
            request.addValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }

        if let requestModifier {
            request = await requestModifier(request)
        }

        logger.info("Sending request", metadata: ["url": "\(request.url!.absoluteString)"])

        // Re-check after the `requestModifier` suspension: `disconnect()` may
        // have invalidated the session while we were awaiting it. Creating a
        // task on an invalidated URLSession raises an uncatchable NSException.
        guard isConnected else {
            throw MCPError.internalError("Transport not connected")
        }

        let (responseData, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPError.internalError("Invalid HTTP response")
        }

        // Process the response based on content type and status code
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""

        // Extract session ID if present
        if let newSessionID = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = newSessionID
            logger.info("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
        }

        // Handle different response types
        switch httpResponse.statusCode {
        case 200, 201, 202:
            // For SSE, the processing happens in the streaming task
            if contentType.contains("text/event-stream") {
                logger.info("Received SSE response, processing in streaming task")
                // The streaming is handled by the SSE task if active
                return
            }

            // For JSON responses, deliver the data directly
            if contentType.contains("application/json"), !responseData.isEmpty {
                logger.info("Received JSON response", metadata: ["size": "\(responseData.count)"])
                messageContinuation.yield(responseData)
            }

        case 400:
            let rawBody = String(data: responseData, encoding: .utf8) ?? "<nil>"
            logger.error("MCP invalid request body: \(rawBody)")
            throw MCPError.invalidRequest(rawBody)

        case 404:
            // If we get a 404 with a session ID, it means our session is invalid
            if sessionID != nil {
                logger.warning("Session has expired")
                sessionID = nil
                throw MCPError.internalError("Session expired")
            }
            throw MCPError.internalError("Endpoint not found")

        case 405:
            throw MCPError.methodNotFound("Method not found")

        default:
            throw MCPError.internalError("HTTP error: \(httpResponse.statusCode)")
        }
    }

    /// Receives data in an async sequence
    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        return messageStream
    }

    // MARK: - SSE

    /// Starts listening for server events using SSE
    private func startListeningForServerEvents() async {
        guard isConnected else { return }
        isListeningForServerEvents = false
        var reconnectAttempt = 0

        while isConnected, !Task.isCancelled {
            do {
                try await connectToEventStream()
                reconnectAttempt = 0
            } catch let error as RetryableSSEError {
                guard !Task.isCancelled else { break }

                guard reconnectAttempt < retryPolicy.maxAttempts else {
                    eventListeningError = MCPError.internalError(
                        "SSE connection failed after \(retryPolicy.maxAttempts) retries"
                    )
                    logger.error("SSE retry limit reached")
                    break
                }

                let delay = reconnectDelay(
                    attempt: reconnectAttempt,
                    retryAfter: error.retryAfter
                )
                reconnectAttempt += 1

                logger.warning(
                    "Retryable SSE HTTP error; reconnecting",
                    metadata: [
                        "statusCode": "\(error.statusCode)",
                        "delay": "\(delay)",
                        "attempt": "\(reconnectAttempt)",
                    ]
                )

                await sleepForReconnectDelay(delay)
            } catch let MCPError.invalidParams(error) {
                eventListeningError = MCPError.invalidParams(error)
                logger.error("Invalid connection parameters: \(error ?? "unknown")")
                break
            } catch let MCPError.unauthorized(wwwAuthenticateHeader) {
                eventListeningError = MCPError.unauthorized(wwwAuthenticateHeader)
                logger.error("Unauthorized")
                break
            } catch MCPError.methodNotFound {
                eventListeningError = MCPError.methodNotFound("Method not found")
                logger.warning("Connection to MCP server does not support this method")
                break
            } catch {
                guard !Task.isCancelled else { break }

                guard isRetryableTransportError(error) else {
                    eventListeningError = (error as? MCPError) ?? MCPError.transportError(error)
                    logger.error("Non-retryable SSE connection error: \(error)")
                    break
                }

                guard reconnectAttempt < retryPolicy.maxAttempts else {
                    eventListeningError = MCPError.transportError(error)
                    logger.error("SSE retry limit reached", metadata: ["error": "\(error)"])
                    break
                }

                let delay = reconnectDelay(attempt: reconnectAttempt, retryAfter: nil)
                reconnectAttempt += 1

                logger.warning(
                    "Retryable SSE transport error; reconnecting",
                    metadata: [
                        "error": "\(error)",
                        "delay": "\(delay)",
                        "attempt": "\(reconnectAttempt)",
                    ]
                )

                await sleepForReconnectDelay(delay)
            }
        }
    }

    private func reconnectDelay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter {
            return min(retryAfter, retryPolicy.maxDelay)
        }

        return min(
            retryPolicy.initialDelay * pow(2, Double(attempt)),
            retryPolicy.maxDelay
        )
    }

    private func sleepForReconnectDelay(_ delay: TimeInterval) async {
        guard delay > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    private func retryAfterDelay(from header: String?) -> TimeInterval? {
        guard let header else { return nil }

        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(trimmed), seconds >= 0 {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"

        guard let date = formatter.date(from: trimmed) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    private func isRetryableTransportError(_ error: Swift.Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }

        switch nsError.code {
        case NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorNotConnectedToInternet:
            return true

        default:
            return false
        }
    }

    #if canImport(FoundationNetworking)
        private func connectToEventStream() async throws {
            logger.warning("SSE is not supported on this platform")
        }
    #else
        /// Establishes an SSE connection to the server
        private func connectToEventStream() async throws {
            guard isConnected else { return }

            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.addValue("text/event-stream", forHTTPHeaderField: "Accept")

            // Add session ID if available
            if let sessionID {
                request.addValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            }

            // Add Last-Event-ID header for resumability if available
            if let lastEventID {
                request.addValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
            }

            if let requestModifier {
                request = await requestModifier(request)
            }

            logger.info("Starting SSE connection")

            guard isConnected else { return }
            // Create URLSession task for SSE
            let (stream, response) = try await session.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw MCPError.internalError("Invalid HTTP response")
            }

            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""

            func consumeBody(_ stream: URLSession.AsyncBytes) async -> String {
                var data = Data()
                do {
                    for try await byte in stream {
                        data.append(byte)
                    }
                } catch {
                    return "<unreadable: \(error)>"
                }
                return String(data: data, encoding: .utf8) ?? ""
            }

            switch httpResponse.statusCode {
            case 200:
                if contentType.starts(with: "text/event-stream") {
                    isListeningForServerEvents = true
                } else {
                    throw MCPError.methodNotFound("Returned content type: \(contentType)")
                }

            case 400:
                let rawBody = await consumeBody(stream)
                throw MCPError.invalidParams("Invalid parameters provided \(rawBody)")

            case 401:
                let wwwAuthHeader = httpResponse.value(forHTTPHeaderField: "WWW-Authenticate")
                throw MCPError.unauthorized(wwwAuthHeader)

            case 408, 429, 502, 503, 504:
                throw RetryableSSEError(
                    statusCode: httpResponse.statusCode,
                    retryAfter: retryAfterDelay(
                        from: httpResponse.value(forHTTPHeaderField: "Retry-After")
                    )
                )

            case 403:
                throw MCPError.internalError("Access forbidden")

            case 404:
                throw MCPError.internalError("Endpoint not found")

            case 405:
                throw MCPError.methodNotFound("Method not found")

            case 406:
                throw MCPError.internalError("Not acceptable")

            case 409:
                throw MCPError.internalError("Connection conflict")

            case 410:
                throw MCPError.internalError("Connection endpoint gone")

            case 415:
                throw MCPError.internalError("Unsupported media type")

            case 500:
                throw MCPError.internalError("HTTP error: 500")

            default:
                throw MCPError.internalError("HTTP error: \(httpResponse.statusCode)")
            }

            // Extract session ID if present
            if let newSessionID = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id") {
                sessionID = newSessionID
            }

            // Process the SSE stream
            var buffer: [UInt8] = []
            var eventType = ""
            var eventID: String?
            var eventData = ""

            for try await byte in stream {
                if Task.isCancelled { break }

                buffer.append(byte)

                if String(bytes: [byte], encoding: .utf8) == "\n" {
                    // Process complete lines
                    Task(priority: .userInitiated) {
                        guard let lines = String(bytes: buffer, encoding: .utf8)
                        else {
                            buffer.removeAll()
                            return
                        }
                        buffer.removeAll()

                        for line in lines.split(separator: "\n", omittingEmptySubsequences: false) {
                            // Empty line marks the end of an event
                            if line.isEmpty || line == "\r" || line == "\n" || line == "\r\n" {
                                if !eventData.isEmpty {
                                    // Process the event
                                    if eventType == "id" {
                                        lastEventID = eventID
                                    } else if eventType == "endpoint" {
                                        if let endpointCommunication {
                                            if let newEndpoint = URL(
                                                string:
                                                "\(endpointCommunication.absoluteString)\(eventData)"
                                            ) {
                                                endpointPostURL = newEndpoint
                                                logger.info(
                                                    "Received new endpoint via SSE with endpointCommunication: \(newEndpoint.absoluteString)"
                                                )
                                            } else {
                                                logger.error(
                                                    "Failed to construct new endpoint URL from SSE data: \(eventData)"
                                                )
                                            }
                                        } else if let scheme = endpoint.scheme,
                                                  let host = endpoint.host
                                        {
                                            // Construct the new endpoint URL using the original scheme and host
                                            let portString = endpoint.port.map { ":\($0)" } ?? ""
                                            if let newEndpoint = URL(
                                                string:
                                                "\(scheme)://\(host)\(portString)\(eventData)"
                                            ) {
                                                endpointPostURL = newEndpoint
                                                logger.info(
                                                    "Received new endpoint via SSE: \(newEndpoint.absoluteString)"
                                                )
                                            } else {
                                                logger.error(
                                                    "Failed to construct new endpoint URL from SSE data: \(eventData)"
                                                )
                                            }
                                        } else {
                                            logger.error(
                                                "Original endpoint is missing scheme or host, cannot construct new endpoint."
                                            )
                                        }
                                    } else {
                                        // Default event type is "message" if not specified
                                        if let data = eventData.data(using: .utf8) {
                                            logger.info(
                                                "SSE event received",
                                                metadata: [
                                                    "type":
                                                        "\(eventType.isEmpty ? "message" : eventType)",
                                                    "id": "\(eventID ?? "none")",
                                                ]
                                            )
                                            messageContinuation.yield(data)
                                        }
                                    }

                                    // Reset for next event
                                    eventType = ""
                                    eventData = ""
                                }
                                return
                            }

                            // Lines starting with ":" are comments
                            if line.hasPrefix(":") { return }

                            // Parse field: value format
                            if let colonIndex = line.firstIndex(of: ":") {
                                let field = String(line[..<colonIndex])
                                var value = String(line[line.index(after: colonIndex)...])

                                // Trim leading space
                                if value.hasPrefix(" ") {
                                    value = String(value.dropFirst())
                                }

                                // Process based on field
                                switch field {
                                case "event":
                                    eventType = value

                                case "data":
                                    if !eventData.isEmpty {
                                        eventData.append("\n")
                                    }
                                    eventData.append(value)

                                case "id":
                                    if !value.contains("\0") { // ID must not contain NULL
                                        eventID = value
                                        lastEventID = value
                                    }

                                case "retry":
                                    // Retry timing not implemented
                                    break

                                default:
                                    // Unknown fields are ignored per SSE spec
                                    break
                                }
                            }
                        }
                    }
                }
            }
        }
    #endif
}
