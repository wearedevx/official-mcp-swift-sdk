import Logging

import struct Foundation.Data
import struct Foundation.Date
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

/// Model Context Protocol client
public actor Client {
    /// The client configuration
    public struct Configuration: Hashable, Codable, Sendable {
        /// The default configuration.
        public static let `default` = Configuration(strict: false)

        /// The strict configuration.
        public static let strict = Configuration(strict: true)

        /// When strict mode is enabled, the client:
        /// - Requires server capabilities to be initialized before making requests
        /// - Rejects all requests that require capabilities before initialization
        ///
        /// While the MCP specification requires servers to respond to initialize requests
        /// with their capabilities, some implementations may not follow this.
        /// Disabling strict mode allows the client to be more lenient with non-compliant
        /// servers, though this may lead to undefined behavior.
        public var strict: Bool

        public init(strict: Bool = false) {
            self.strict = strict
        }
    }

    /// Implementation information
    public struct Info: Hashable, Codable, Sendable {
        /// The client name
        public var name: String
        /// The client version
        public var version: String

        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }
    }

    /// The client capabilities
    public struct Capabilities: Hashable, Codable, Sendable {
        /// The roots capabilities
        public struct Roots: Hashable, Codable, Sendable {
            /// Whether the list of roots has changed
            public var listChanged: Bool?

            public init(listChanged: Bool? = nil) {
                self.listChanged = listChanged
            }
        }

        /// The sampling capabilities
        public struct Sampling: Hashable, Codable, Sendable {
            public init() {}
        }

        /// Whether the client supports sampling
        public var sampling: Sampling?
        /// Experimental features supported by the client
        public var experimental: [String: String]?
        /// Whether the client supports roots
        public var roots: Capabilities.Roots?

        public init(
            sampling: Sampling? = nil,
            experimental: [String: String]? = nil,
            roots: Capabilities.Roots? = nil
        ) {
            self.sampling = sampling
            self.experimental = experimental
            self.roots = roots
        }
    }

    /// The connection to the server
    private var connection: (any Transport)?
    /// The logger for the client
    private var logger: Logger? {
        get async {
            await connection?.logger
        }
    }

    /// The client information
    private let clientInfo: Client.Info
    /// The client name
    public nonisolated var name: String { clientInfo.name }
    /// The client version
    public nonisolated var version: String { clientInfo.version }

    /// The client capabilities
    public var capabilities: Client.Capabilities
    /// The client configuration
    public var configuration: Configuration

    /// The server capabilities
    private var serverCapabilities: Server.Capabilities?
    /// The server version
    private var serverVersion: String?
    /// The server instructions
    private var instructions: String?

    /// A dictionary of type-erased notification handlers, keyed by method name
    private var notificationHandlers: [String: [NotificationHandlerBox]] = [:]
    /// The task for the message handling loop
    private var task: Task<Void, Never>?

    /// An error indicating a type mismatch when decoding a pending request
    private struct TypeMismatchError: Swift.Error {}

    /// A pending request with a continuation for the result
    private class PendingRequest<T: Sendable> {
        private let continuation: CheckedContinuation<T, Swift.Error>
        var used: Bool

        init(continuation: CheckedContinuation<T, Swift.Error>) {
            self.continuation = continuation
            used = false
        }

        // Wrap the continuation to avoid calling resume twice
        func resume(returning value: T) {
            if !used {
                continuation.resume(returning: value)
                used = true
            }
        }

        // Wrap the continuation to avoid calling resume twice
        func resume(throwing error: Swift.Error) {
            if !used {
                continuation.resume(throwing: error)
                used = false
            }
        }
    }

    /// A type-erased pending request
    private struct AnyPendingRequest {
        private let _resume: (Result<Any, Swift.Error>) -> Void

        init<T: Sendable & Decodable>(_ request: PendingRequest<T>) {
            _resume = { result in
                switch result {
                case .success(let value):
                    if let typedValue = value as? T {
                        request.resume(returning: typedValue)
                    } else if let value = value as? Value,
                              let data = try? JSONEncoder().encode(value),
                              let decoded = try? JSONDecoder().decode(T.self, from: data)
                    {
                        request.resume(returning: decoded)
                    } else {
                        request.resume(throwing: TypeMismatchError())
                    }
                case .failure(let error):
                    request.resume(throwing: error)
                }
            }
        }

        func resume(returning value: Any) {
            _resume(.success(value))
        }

        func resume(throwing error: Swift.Error) {
            _resume(.failure(error))
        }
    }

    /// A dictionary of type-erased pending requests, keyed by request ID
    private var pendingRequests: [ID: AnyPendingRequest] = [:]
    // Add reusable JSON encoder/decoder
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        name: String,
        version: String,
        configuration: Configuration = .default
    ) {
        clientInfo = Client.Info(name: name, version: version)
        capabilities = Capabilities()
        self.configuration = configuration
    }

    /// Connect to the server using the given transport
    public func connect(transport: any Transport) async throws {
        connection = transport
        try await connection?.connect()

        await logger?.info(
            "Client connected", metadata: ["name": "\(name)", "version": "\(version)"])

        // Start message handling loop
        task = Task {
            guard let connection = self.connection else { return }
            repeat {
                // Check for cancellation before starting the iteration
                if Task.isCancelled { break }

                do {
                    let stream = await connection.receive()
                    for try await data in stream {
                        if Task.isCancelled { break } // Check inside loop too

                        // Attempt to decode data
                        // Try decoding as a batch response first
                        if let batchResponse = try? decoder.decode([AnyResponse].self, from: data) {
                            await handleBatchResponse(batchResponse)
                        } else if let response = try? decoder.decode(AnyResponse.self, from: data),
                                  let request = pendingRequests[response.id]
                        {
                            await handleResponse(response, for: request)
                        } else if let message = try? decoder.decode(AnyMessage.self, from: data) {
                            await handleMessage(message)
                        } else {
                            var metadata: Logger.Metadata = [:]
                            if let string = String(data: data, encoding: .utf8) {
                                metadata["message"] = .string(string)
                            }
                            await logger?.warning(
                                "Unexpected message received by client (not single/batch response or notification)",
                                metadata: metadata)
                        }
                    }
                } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                    try? await Task.sleep(for: .milliseconds(10))
                    continue
                } catch {
                    await logger?.error(
                        "Error in message handling loop", metadata: ["error": "\(error)"])
                    break
                }
            } while true
        }
    }

    /// Disconnect the client and cancel all pending requests
    public func disconnect() async {
        // Cancel all pending requests
        for (id, request) in pendingRequests {
            request.resume(throwing: MCPError.internalError("Client disconnected"))
            pendingRequests.removeValue(forKey: id)
        }

        task?.cancel()
        task = nil
        if let connection = connection {
            await connection.disconnect()
        }
        connection = nil
    }

    // MARK: - Registration

    /// Register a handler for a notification
    @discardableResult
    public func onNotification<N: Notification>(
        _ type: N.Type,
        handler: @escaping @Sendable (Message<N>) async throws -> Void
    ) async -> Self {
        let handlers = notificationHandlers[N.name, default: []]
        notificationHandlers[N.name] = handlers + [TypedNotificationHandler(handler)]
        return self
    }

    // MARK: - Requests

    /// Send a request and receive its response
    public func send<M: Method>(_ request: Request<M>) async throws -> M.Result {
        guard let connection = connection else {
            throw MCPError.internalError("Client connection not initialized")
        }

        // Use the actor's encoder
        let requestData = try encoder.encode(request)

        // Store the pending request first
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                self.addPendingRequest(
                    id: request.id,
                    continuation: continuation,
                    type: M.Result.self)

                // Send the request data
                do {
                    // Use the existing connection send
                    try await connection.send(requestData)
                } catch {
                    // We need to check if the pending request is still present
                    // because it might have been used anyway
                    if self.hasPendingRequest(id: request.id),
                       let pendingRequest = self.pendingRequests[request.id]
                    {
                        // If send fails immediately, resume continuation and remove pending request
                        pendingRequest.resume(throwing: error)
                        self.removePendingRequest(id: request.id) // Ensure cleanup on send error
                    }
                }
            }
        }
    }

    private func addPendingRequest<T: Sendable & Decodable>(
        id: ID,
        continuation: CheckedContinuation<T, Swift.Error>,
        type: T.Type // Keep type for AnyPendingRequest internal logic
    ) {
        pendingRequests[id] = AnyPendingRequest(PendingRequest(continuation: continuation))
    }

    private func hasPendingRequest(id: ID) -> Bool {
        pendingRequests[id] != nil
    }

    private func removePendingRequest(id: ID) {
        pendingRequests.removeValue(forKey: id)
    }

    // MARK: - Batching

    /// A batch of requests.
    ///
    /// Objects of this type are passed as an argument to the closure
    /// of the ``Client/withBatch(_:)`` method.
    public actor Batch {
        unowned let client: Client
        var requests: [AnyRequest] = []

        init(client: Client) {
            self.client = client
        }

        /// Adds a request to the batch and prepares its expected response task.
        /// The actual sending happens when the `withBatch` scope completes.
        /// - Returns: A `Task` that will eventually produce the result or throw an error.
        public func addRequest<M: Method>(_ request: Request<M>) async throws -> Task<
            M.Result, Swift.Error
        > {
            try requests.append(AnyRequest(request))

            // Return a Task that registers the pending request and awaits its result.
            // The continuation is resumed when the response arrives.
            return Task<M.Result, Swift.Error> {
                try await withCheckedThrowingContinuation { continuation in
                    // We are already inside a Task, but need another Task
                    // to bridge to the client actor's context.
                    Task {
                        await client.addPendingRequest(
                            id: request.id,
                            continuation: continuation,
                            type: M.Result.self)
                    }
                }
            }
        }
    }

    /// Executes multiple requests in a single batch.
    ///
    /// This method allows you to group multiple MCP requests together,
    /// which are then sent to the server as a single JSON array.
    /// The server processes these requests and sends back a corresponding
    /// JSON array of responses.
    ///
    /// Within the `body` closure, use the provided `Batch` actor to add
    /// requests using `batch.addRequest(_:)`. Each call to `addRequest`
    /// returns a `Task` handle representing the asynchronous operation
    /// for that specific request's result.
    ///
    /// It's recommended to collect these `Task` handles into an array
    /// within the `body` closure`. After the `withBatch` method returns
    /// (meaning the batch request has been sent), you can then process
    /// the results by awaiting each `Task` in the collected array.
    ///
    /// Example 1: Batching multiple tool calls and collecting typed tasks:
    /// ```swift
    /// // Array to hold the task handles for each tool call
    /// var toolTasks: [Task<CallTool.Result, Error>] = []
    /// try await client.withBatch { batch in
    ///     for i in 0..<10 {
    ///         toolTasks.append(
    ///             try await batch.addRequest(
    ///                 CallTool.request(.init(name: "square", arguments: ["n": i]))
    ///             )
    ///         )
    ///     }
    /// }
    ///
    /// // Process results after the batch is sent
    /// print("Processing \(toolTasks.count) tool results...")
    /// for (index, task) in toolTasks.enumerated() {
    ///     do {
    ///         let result = try await task.value
    ///         print("\(index): \(result.content)")
    ///     } catch {
    ///         print("\(index) failed: \(error)")
    ///     }
    /// }
    /// ```
    ///
    /// Example 2: Batching different request types and awaiting individual tasks:
    /// ```swift
    /// // Declare optional task variables beforehand
    /// var pingTask: Task<Ping.Result, Error>?
    /// var promptTask: Task<GetPrompt.Result, Error>?
    ///
    /// try await client.withBatch { batch in
    ///     // Assign the tasks within the batch closure
    ///     pingTask = try await batch.addRequest(Ping.request())
    ///     promptTask = try await batch.addRequest(GetPrompt.request(.init(name: "greeting")))
    /// }
    ///
    /// // Await the results after the batch is sent
    /// do {
    ///     if let pingTask = pingTask {
    ///         try await pingTask.value // Await ping result (throws if ping failed)
    ///         print("Ping successful")
    ///     }
    ///     if let promptTask = promptTask {
    ///         let promptResult = try await promptTask.value // Await prompt result
    ///         print("Prompt description: \(promptResult.description ?? "None")")
    ///     }
    /// } catch {
    ///     print("Error processing batch results: \(error)")
    /// }
    /// ```
    ///
    /// - Parameter body: An asynchronous closure that takes a `Batch` object as input.
    ///                   Use this object to add requests to the batch.
    /// - Throws: `MCPError.internalError` if the client is not connected.
    ///           Can also rethrow errors from the `body` closure or from sending the batch request.
    public func withBatch(body: @escaping (Batch) async throws -> Void) async throws {
        guard let connection = connection else {
            throw MCPError.internalError("Client connection not initialized")
        }

        // Create Batch actor, passing self (Client)
        let batch = Batch(client: self)

        // Populate the batch actor by calling the user's closure.
        try await body(batch)

        // Get the collected requests from the batch actor
        let requests = await batch.requests

        // Check if there are any requests to send
        guard !requests.isEmpty else {
            await logger?.info("Batch requested but no requests were added.")
            return // Nothing to send
        }

        await logger?.debug(
            "Sending batch request", metadata: ["count": "\(requests.count)"])

        // Encode the array of AnyMethod requests into a single JSON payload
        let data = try encoder.encode(requests)
        try await connection.send(data)

        // Responses will be handled asynchronously by the message loop and handleBatchResponse/handleResponse.
    }

    // MARK: - Lifecycle

    public func initialize() async throws -> Initialize.Result {
        let request = Initialize.request(
            .init(
                protocolVersion: Version.latest,
                capabilities: capabilities,
                clientInfo: clientInfo))

        let result = try await send(request)

        serverCapabilities = result.capabilities
        serverVersion = result.protocolVersion
        instructions = result.instructions

        return result
    }

    public func ping() async throws {
        let request = Ping.request()
        _ = try await send(request)
    }

    // MARK: - Prompts

    public func getPrompt(name: String, arguments: [String: Value]? = nil) async throws
        -> (description: String?, messages: [Prompt.Message])
    {
        try validateServerCapability(\.prompts, "Prompts")
        let request = GetPrompt.request(.init(name: name, arguments: arguments))
        let result = try await send(request)
        return (description: result.description, messages: result.messages)
    }

    public func listPrompts(cursor: String? = nil) async throws
        -> (prompts: [Prompt], nextCursor: String?)
    {
        try validateServerCapability(\.prompts, "Prompts")
        let request: Request<ListPrompts>
        if let cursor = cursor {
            request = ListPrompts.request(.init(cursor: cursor))
        } else {
            request = ListPrompts.request(.init())
        }
        let result = try await send(request)
        return (prompts: result.prompts, nextCursor: result.nextCursor)
    }

    // MARK: - Resources

    public func readResource(uri: String) async throws -> [Resource.Content] {
        try validateServerCapability(\.resources, "Resources")
        let request = ReadResource.request(.init(uri: uri))
        let result = try await send(request)
        return result.contents
    }

    public func listResources(cursor: String? = nil) async throws -> (
        resources: [Resource], nextCursor: String?
    ) {
        try validateServerCapability(\.resources, "Resources")
        let request: Request<ListResources>
        if let cursor = cursor {
            request = ListResources.request(.init(cursor: cursor))
        } else {
            request = ListResources.request(.init())
        }
        let result = try await send(request)
        return (resources: result.resources, nextCursor: result.nextCursor)
    }

    public func subscribeToResource(uri: String) async throws {
        try validateServerCapability(\.resources?.subscribe, "Resource subscription")
        let request = ResourceSubscribe.request(.init(uri: uri))
        _ = try await send(request)
    }

    // MARK: - Tools

    public func listTools(cursor: String? = nil) async throws -> (
        tools: [Tool], nextCursor: String?
    ) {
        try validateServerCapability(\.tools, "Tools")
        let request: Request<ListTools>
        if let cursor = cursor {
            request = ListTools.request(.init(cursor: cursor))
        } else {
            request = ListTools.request(.init())
        }
        let result = try await send(request)
        return (tools: result.tools, nextCursor: result.nextCursor)
    }

    public func callTool(name: String, arguments: [String: Value]? = nil) async throws -> (
        content: [Tool.Content], isError: Bool?
    ) {
        try validateServerCapability(\.tools, "Tools")
        let request = CallTool.request(.init(name: name, arguments: arguments))
        let result = try await send(request)
        return (content: result.content, isError: result.isError)
    }

    // MARK: -

    private func handleResponse(_ response: Response<AnyMethod>, for request: AnyPendingRequest)
        async
    {
        await logger?.debug(
            "Processing response",
            metadata: ["id": "\(response.id)"])

        switch response.result {
        case .success(let value):
            request.resume(returning: value)
        case .failure(let error):
            request.resume(throwing: error)
        }

        removePendingRequest(id: response.id)
    }

    private func handleMessage(_ message: Message<AnyNotification>) async {
        await logger?.debug(
            "Processing notification",
            metadata: ["method": "\(message.method)"])

        // Find notification handlers for this method
        guard let handlers = notificationHandlers[message.method] else { return }

        // Convert notification parameters to concrete type and call handlers
        for handler in handlers {
            do {
                try await handler(message)
            } catch {
                await logger?.error(
                    "Error handling notification",
                    metadata: [
                        "method": "\(message.method)",
                        "error": "\(error)",
                    ])
            }
        }
    }

    // MARK: -

    /// Validate the server capabilities.
    /// Throws an error if the client is configured to be strict and the capability is not supported.
    private func validateServerCapability<T>(
        _ keyPath: KeyPath<Server.Capabilities, T?>,
        _ name: String
    )
        throws
    {
        if configuration.strict {
            guard let capabilities = serverCapabilities else {
                throw MCPError.methodNotFound("Server capabilities not initialized")
            }
            guard capabilities[keyPath: keyPath] != nil else {
                throw MCPError.methodNotFound("\(name) is not supported by the server")
            }
        }
    }

    // Add handler for batch responses
    private func handleBatchResponse(_ responses: [AnyResponse]) async {
        await logger?.debug("Processing batch response", metadata: ["count": "\(responses.count)"])
        for response in responses {
            // Look up the pending request for this specific ID within the batch
            if let request = pendingRequests[response.id] {
                // Reuse the existing single response handler logic
                await handleResponse(response, for: request)
            } else {
                // Log if a response ID doesn't match any pending request
                await logger?.warning(
                    "Received response in batch for unknown request ID",
                    metadata: ["id": "\(response.id)"])
            }
        }
    }
}
