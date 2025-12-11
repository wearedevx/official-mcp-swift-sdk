import Foundation
import Logging

public actor StreamableHTTPTransport: Transport {
    public var logger: Logging.Logger =
        Logger(label: "mcp.client.streamable-http.transport")

    var endpoint: URL
    var endpointCommunication: URL?

    private var sessionID: String?
    private var lastEventID: String?

    private var session: URLSession
    private var listenerSession: URLSession
    private var isConnected = false
    private var isListeningForServerEvents = false

    private var sendingError: MCPError?
    private var eventListeningError: MCPError?
    private var streamingTask: Task<Void, Never>?

    private let requestModifier: (@Sendable (URLRequest) async throws -> URLRequest)?

    private var messageStream: AsyncThrowingStream<Data, Swift.Error>
    private var messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    public init(
        endpoint: URL,
        session: URLSession,
        requestModifier: (@Sendable (URLRequest) async throws -> URLRequest)? = nil,
        logger: Logger? = nil
    ) {
        self.endpoint = endpoint
        endpointCommunication = endpoint
        self.requestModifier = requestModifier
        self.session = session

        listenerSession = Self.createListenerSession()

        let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()

        messageStream = stream
        messageContinuation = continuation

        if let logger {
            self.logger = logger
        }

        self.logger.info("Streamable HTTP client transport initialized sessionID == nil")
    }

    private nonisolated static func createListenerSession() -> URLSession {
        let listenerConfiguration = URLSessionConfiguration.default
        listenerConfiguration.timeoutIntervalForRequest = .infinity
        listenerConfiguration.timeoutIntervalForResource = .infinity
        listenerConfiguration.httpAdditionalHeaders = ["Accept": "text/event-stream"]

        return URLSession(configuration: listenerConfiguration)
    }

    public func connect() async throws {
        eventListeningError = nil

        guard !isConnected else { return }
        isConnected = true

        streamingTask = Task.detached { await self.startListeningForServerEvents() }

        // wait for the connection to happen with a valid endpoint
        let timeoutNs = 45_000_000_000 // 45 seconds
        let sleepIntervalNs: UInt64 = 50_000_000 // 50 ms
        var elapsedNs: UInt64 = 0

        while isListeningForServerEvents == false, eventListeningError == nil {
            if elapsedNs >= timeoutNs {
                throw MCPError.internalError("Timeout waiting for valid endpoint from SSE")
            }
            try await Task.sleep(nanoseconds: sleepIntervalNs)
            elapsedNs += sleepIntervalNs
        }

        if let eventListeningError {
            logger.warning(
                "HTTP transport failed to connect: \(eventListeningError.localizedDescription)")
        }

        logger.info("HTTP transport connected")
    }

    public func disconnect() async {
        messageContinuation.finish()
        isConnected = false

        streamingTask?.cancel()
        streamingTask = nil
        session.finishTasksAndInvalidate()
        listenerSession.finishTasksAndInvalidate()

        logger.info("HTTP clienttransport disconnected")
    }

    public func send(_ data: Data) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        request.httpBody = data

        // Add session ID if available
        if let sessionID {
            request.addValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }

        if let requestModifier {
            request = try await requestModifier(request)
        }

        let (stream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPError.internalError("Invalid HTTP response")
        }

        // Process the response based on content type and status code
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""

        // Extract session ID if present
        if let newSessionID = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = newSessionID
            logger.debug("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
        }

        func consumeBody(_ stream: URLSession.AsyncBytes) async -> String {
            var data = Data()

            do {
                for try await byte in stream {
                    data.append(byte)
                }
            } catch {
                logger.error("Failed to read response body: \(error)")
                return "<unreadable: \(error)>"
            }

            return String(data: data, encoding: .utf8) ?? "<nil>"
        }

        // Handle different response types
        switch httpResponse.statusCode {
        case 200, 201, 202:
            // For SSE, the processing happens in the streaming task
            if contentType.contains("text/event-stream") {
                logger.info("Received SSE response, processing in streaming task")

                let continuation = messageContinuation
                try await decodeSSEStream(stream) { message in
                    continuation.yield(message)
                }
                return
            }

            // For JSON responses, deliver the data directly
            if contentType.contains("application/json") {
                var data = Data()
                for try await byte in stream {
                    data.append(byte)
                }

                messageContinuation.yield(data)
            }

        case 400:
            let rawBody = await consumeBody(stream)
            logger.error("MCP invalid request body: \(rawBody)")
            throw MCPError.invalidRequest(rawBody)

        case 401:
            let wwwAuthenticate = httpResponse.value(forHTTPHeaderField: "WWW-Authenticate")
            throw MCPError.unauthorized(wwwAuthenticate)

        case 404:
            // If we get a 404 with a session ID, it means our session is invalid
            if sessionID != nil {
                logger.warning("Session has expired")
                sessionID = nil
                throw MCPError.internalError("Session expired")
            }
            throw MCPError.invalidRequest("Endpoint not found")

        case 405:
            throw MCPError.methodNotFound("Method not found")

        default:
            throw MCPError.internalError("HTTP error: \(httpResponse.statusCode)")
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        // Finish any existing stream/coninaution and create a new one,
        // because we can't more than one task listening of het same stream
        messageContinuation.finish()

        let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        messageContinuation = continuation
        messageStream = stream

        return stream
    }

    private func decodeSSEStream(
        _ stream: URLSession.AsyncBytes, handleMessage: @escaping @Sendable (Data) async -> Void
    ) async throws {
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
                                            endpoint = newEndpoint
                                            logger.info(
                                                "Received new endpoint via SSE with endpointCommunication: \(newEndpoint.absoluteString)"
                                            )
                                        } else {
                                            logger.error(
                                                "Failed to construct new endpoint URL from SSE data: \(eventData)"
                                            )
                                        }
                                    } else if let scheme = endpoint.scheme, let host = endpoint.host {
                                        // Construct the new endpoint URL using the original scheme and host
                                        let portString = endpoint.port.map { ":\($0)" } ?? ""
                                        if let newEndpoint = URL(
                                            string: "\(scheme)://\(host)\(portString)\(eventData)")
                                        {
                                            endpoint = newEndpoint
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
                                        logger.debug(
                                            "SSE event received",
                                            metadata: [
                                                "type":
                                                    "\(eventType.isEmpty ? "message" : eventType)",
                                                "id": "\(eventID ?? "none")",
                                            ]
                                        )
                                        await handleMessage(data)
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

    /// Establishes an SSE connection to the server
    private func connectToEventStream() async throws {
        guard isConnected else { return }
        listenerSession.finishTasksAndInvalidate()
        listenerSession = Self.createListenerSession()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.addValue("text/event-stream", forHTTPHeaderField: "Accept")

        request.addValue(Version.latest, forHTTPHeaderField: "MCP-Protocol-Version")

        // Add session ID if available
        if let sessionID {
            request.addValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }

        // Add Last-Event-ID header for resumability if available
        if let lastEventID {
            request.addValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
        }

        if let requestModifier {
            request = try await requestModifier(request)
        }

        logger.info("Starting SSE connection")

        // Create URLSession task for SSE
        let (stream, response) = try await listenerSession.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPError.internalError("Invalid HTTP response")
        }

        // Extract session ID if present
        if let newSessionID = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id") {
            logger.info("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
            sessionID = newSessionID
        }

        func consumeBody(_ stream: URLSession.AsyncBytes) async throws -> String {
            var data = Data()
            for try await byte in stream {
                data.append(byte)
            }
            return String(data: data, encoding: .utf8) ?? ""
        }

        switch httpResponse.statusCode {
        case 200, 201, 202:
            isListeningForServerEvents = true

        case 400:
            let rawBody = try? await consumeBody(stream)
            logger.error("MCP Connection invalid params BODY: \(rawBody ?? "<nil>")")
            throw MCPError.invalidParams("Invalid parameters provided \(rawBody ?? "<nil>")")

        case 401:
            let wwwAuthenticateHeader = httpResponse.value(
                forHTTPHeaderField: "WWW-Authenticate")
            throw MCPError.unauthorized(wwwAuthenticateHeader)

        case 404:
            let rawBody = try? await consumeBody(stream)
            logger.error("MCP Connection Endpoint not found BODY: \(rawBody ?? "<nil>")")
            throw MCPError.internalError("Endpoint not found")

        case 405:
            throw MCPError.methodNotFound("Method not found")

        default:
            throw MCPError.internalError("HTTP error: \(httpResponse.statusCode)")
        }

        // Process the SSE stream
        // Capture continuation locally for actor safety
        let continuation = messageContinuation
        try await decodeSSEStream(stream) { message in
            continuation.yield(message)
        }
    }

    private func startListeningForServerEvents() async {
        guard isConnected else { return }
        isListeningForServerEvents = false

        // Retry loop for connection drops
        while isConnected, !Task.isCancelled {
            do {
                try await connectToEventStream()
            } catch let MCPError.invalidParams(error) {
                logger.error("Invalid connection parameters: \(error ?? "unknow")")
                self.eventListeningError = MCPError.invalidParams(error)
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
                if !Task.isCancelled {
                    logger.error("SSE connection error: \(error)")
                    // Wait before retrying
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                }
            }
        }
    }
}
