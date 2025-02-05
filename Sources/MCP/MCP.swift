import Foundation

/// Protocol version constants
public enum MCPVersion {
    public static let latest = "1.0.0"
    public static let supported = ["1.0.0"]
}

/// MCP error types
public enum MCPError: LocalizedError {
    case connectionClosed
    case invalidResponse
    case invalidParams(String)
    case serverError(String)
    case protocolError(String)
    case transportError(Error)
    
    public var errorDescription: String? {
        switch self {
        case .connectionClosed:
            return "Connection closed"
        case .invalidResponse:
            return "Invalid response from server"
        case .invalidParams(let message):
            return "Invalid parameters: \(message)"
        case .serverError(let message):
            return "Server error: \(message)"
        case .protocolError(let message):
            return "Protocol error: \(message)"
        case .transportError(let error):
            return "Transport error: \(error.localizedDescription)"
        }
    }
}

/// Base protocol for MCP messages
public protocol MCPMessage: Codable {
    var jsonrpc: String { get }
}

/// Protocol for MCP requests
public protocol MCPRequest: MCPMessage {
    var id: String { get }
    var method: String { get }
}

/// Protocol for MCP notifications
public protocol MCPNotification: MCPMessage {
    var method: String { get }
}

/// Protocol for MCP responses
public protocol MCPResponse: MCPMessage {
    var id: String { get }
}

/// Implementation information
public struct Implementation: Codable {
    public let name: String
    public let version: String
    
    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

/// Client capabilities
public struct ClientCapabilities: Codable {
    public var sampling: Bool?
    public var experimental: [String: [String: Any]]?
    public var roots: RootsCapability?
    
    public init(sampling: Bool? = nil, 
                experimental: [String: [String: Any]]? = nil,
                roots: RootsCapability? = nil) {
        self.sampling = sampling
        self.experimental = experimental
        self.roots = roots
    }
    
    enum CodingKeys: String, CodingKey {
        case sampling
        case experimental
        case roots
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sampling = try container.decodeIfPresent(Bool.self, forKey: .sampling)
        experimental = try container.decodeIfPresent([String: [String: Any]].self, forKey: .experimental)
        roots = try container.decodeIfPresent(RootsCapability.self, forKey: .roots)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(sampling, forKey: .sampling)
        try container.encodeIfPresent(experimental, forKey: .experimental)
        try container.encodeIfPresent(roots, forKey: .roots)
    }
}

/// Roots capability configuration
public struct RootsCapability: Codable {
    public var listChanged: Bool?
    
    public init(listChanged: Bool? = nil) {
        self.listChanged = listChanged
    }
}

/// Server capabilities
public struct ServerCapabilities: Codable {
    public var logging: Bool?
    public var prompts: Bool?
    public var resources: ResourcesCapability?
    public var tools: Bool?
    
    public init(logging: Bool? = nil,
                prompts: Bool? = nil,
                resources: ResourcesCapability? = nil,
                tools: Bool? = nil) {
        self.logging = logging
        self.prompts = prompts
        self.resources = resources
        self.tools = tools
    }
}

/// Resources capability configuration
public struct ResourcesCapability: Codable {
    public var subscribe: Bool?
    
    public init(subscribe: Bool? = nil) {
        self.subscribe = subscribe
    }
}

/// Initialize request parameters
public struct InitializeRequestParams: Codable {
    public let protocolVersion: String
    public let capabilities: ClientCapabilities
    public let clientInfo: Implementation
    
    public init(protocolVersion: String = MCPVersion.latest,
                capabilities: ClientCapabilities,
                clientInfo: Implementation) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.clientInfo = clientInfo
    }
}

/// Initialize request
public struct InitializeRequest: MCPRequest {
    public let jsonrpc: String = "2.0"
    public let id: String
    public let method: String = "initialize"
    public let params: InitializeRequestParams
    
    public init(id: String = UUID().uuidString, params: InitializeRequestParams) {
        self.id = id
        self.params = params
    }
}

/// Initialize result
public struct InitializeResult: MCPResponse {
    public let jsonrpc: String = "2.0"
    public let id: String
    public let result: InitializeResultData
    
    public struct InitializeResultData: Codable {
        public let protocolVersion: String
        public let capabilities: ServerCapabilities
        public let serverInfo: Implementation
        public let instructions: String?
    }
}

/// MCP Client protocol
public protocol MCPClientProtocol {
    func connect() async throws
    func disconnect() async
    func initialize() async throws -> InitializeResult
    func ping() async throws
    
    // Resource methods
    func listResources() async throws -> ListResourcesResponse
    func readResource(_ uri: String) async throws -> ReadResourceResponse
    func subscribeResource(_ uri: String) async throws
    func unsubscribeResource(_ uri: String) async throws
    
    // Tool methods
    func listTools() async throws -> ListToolsResponse
    func callTool(name: String, arguments: [String: Any]? = nil) async throws -> CallToolResponse
}

/// MCP Client implementation
public actor MCPClient: MCPClientProtocol {
    private let transport: MCPTransport
    private let clientInfo: Implementation
    private var capabilities: ClientCapabilities
    private var serverCapabilities: ServerCapabilities?
    private var serverVersion: Implementation?
    private var instructions: String?
    
    public init(transport: MCPTransport,
                clientInfo: Implementation,
                capabilities: ClientCapabilities = ClientCapabilities()) {
        self.transport = transport
        self.clientInfo = clientInfo
        self.capabilities = capabilities
    }
    
    public func connect() async throws {
        try await transport.connect()
    }
    
    public func disconnect() async {
        await transport.disconnect()
    }
    
    public func initialize() async throws -> InitializeResult {
        let request = InitializeRequest(params: InitializeRequestParams(
            capabilities: capabilities,
            clientInfo: clientInfo
        ))
        
        let response: InitializeResult = try await sendRequest(request)
        
        // Validate protocol version
        guard MCPVersion.supported.contains(response.result.protocolVersion) else {
            throw MCPError.protocolError("Unsupported protocol version: \(response.result.protocolVersion)")
        }
        
        // Store server information
        serverCapabilities = response.result.capabilities
        serverVersion = response.result.serverInfo
        instructions = response.result.instructions
        
        // Send initialized notification
        try await sendNotification(InitializedNotification())
        
        return response
    }
    
    public func ping() async throws {
        let request = PingRequest()
        try await sendRequest(request)
    }
    
    // MARK: - Resource Methods
    
    public func listResources() async throws -> ListResourcesResponse {
        guard serverCapabilities?.resources != nil else {
            throw MCPError.protocolError("Server does not support resources")
        }
        
        let request = ListResourcesRequest()
        return try await sendRequest(request)
    }
    
    public func readResource(_ uri: String) async throws -> ReadResourceResponse {
        guard serverCapabilities?.resources != nil else {
            throw MCPError.protocolError("Server does not support resources")
        }
        
        let request = ReadResourceRequest(uri: uri)
        return try await sendRequest(request)
    }
    
    public func subscribeResource(_ uri: String) async throws {
        guard let resources = serverCapabilities?.resources,
              resources.subscribe == true else {
            throw MCPError.protocolError("Server does not support resource subscriptions")
        }
        
        let request = SubscribeRequest(uri: uri)
        try await sendRequest(request)
    }
    
    public func unsubscribeResource(_ uri: String) async throws {
        guard let resources = serverCapabilities?.resources,
              resources.subscribe == true else {
            throw MCPError.protocolError("Server does not support resource subscriptions")
        }
        
        let request = UnsubscribeRequest(uri: uri)
        try await sendRequest(request)
    }
    
    // MARK: - Tool Methods
    
    public func listTools() async throws -> ListToolsResponse {
        guard serverCapabilities?.tools == true else {
            throw MCPError.protocolError("Server does not support tools")
        }
        
        let request = ListToolsRequest()
        return try await sendRequest(request)
    }
    
    public func callTool(name: String, arguments: [String: Any]? = nil) async throws -> CallToolResponse {
        guard serverCapabilities?.tools == true else {
            throw MCPError.protocolError("Server does not support tools")
        }
        
        let request = CallToolRequest(name: name, arguments: arguments)
        return try await sendRequest(request)
    }
    
    private func sendRequest<T: MCPRequest, U: MCPResponse>(_ request: T) async throws -> U {
        let data = try JSONEncoder().encode(request)
        let responseData = try await transport.sendRequest(data)
        return try JSONDecoder().decode(U.self, from: responseData)
    }
    
    private func sendNotification<T: MCPNotification>(_ notification: T) async throws {
        let data = try JSONEncoder().encode(notification)
        try await transport.sendNotification(data)
    }
    
    // MARK: - Public Properties
    
    /// Get the server's capabilities after initialization
    public var serverCapabilitiesAfterInit: ServerCapabilities? {
        serverCapabilities
    }
    
    /// Get the server's version information after initialization
    public var serverVersionAfterInit: Implementation? {
        serverVersion
    }
    
    /// Get the server's instructions after initialization
    public var serverInstructions: String? {
        instructions
    }
}

/// MCP Transport protocol
public protocol MCPTransport {
    func connect() async throws
    func disconnect() async
    func sendRequest(_ data: Data) async throws -> Data
    func sendNotification(_ data: Data) async throws
}

/// Basic notification types
public struct InitializedNotification: MCPNotification {
    public let jsonrpc: String = "2.0"
    public let method: String = "notifications/initialized"
}

public struct PingRequest: MCPRequest {
    public let jsonrpc: String = "2.0"
    public let id: String
    public let method: String = "ping"
    
    public init(id: String = UUID().uuidString) {
        self.id = id
    }
}
