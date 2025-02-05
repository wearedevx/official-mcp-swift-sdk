import Foundation

/// Resource metadata
public struct ResourceMetadata: Codable {
    public var name: String
    public var uri: String
    public var metadata: [String: String]?
    
    public init(name: String, uri: String, metadata: [String: String]? = nil) {
        self.name = name
        self.uri = uri
        self.metadata = metadata
    }
}

/// Resource content types
public enum ResourceContent: Codable {
    case text(String)
    case binary(Data)
    case embedded([EmbeddedResource])
    
    private enum CodingKeys: String, CodingKey {
        case type
        case content
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        
        switch type {
        case "text":
            let content = try container.decode(String.self, forKey: .content)
            self = .text(content)
        case "binary":
            let content = try container.decode(Data.self, forKey: .content)
            self = .binary(content)
        case "embedded":
            let content = try container.decode([EmbeddedResource].self, forKey: .content)
            self = .embedded(content)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown resource type")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .text(let content):
            try container.encode("text", forKey: .type)
            try container.encode(content, forKey: .content)
        case .binary(let content):
            try container.encode("binary", forKey: .type)
            try container.encode(content, forKey: .content)
        case .embedded(let content):
            try container.encode("embedded", forKey: .type)
            try container.encode(content, forKey: .content)
        }
    }
}

/// Embedded resource type
public struct EmbeddedResource: Codable {
    public var type: String
    public var data: String
    public var metadata: [String: String]?
    
    public init(type: String, data: String, metadata: [String: String]? = nil) {
        self.type = type
        self.data = data
        self.metadata = metadata
    }
}

/// Resource request types
public struct ListResourcesRequest: MCPRequest {
    public let jsonrpc: String = "2.0"
    public let id: String
    public let method: String = "resources/list"
    
    public init(id: String = UUID().uuidString) {
        self.id = id
    }
}

public struct ReadResourceRequest: MCPRequest {
    public let jsonrpc: String = "2.0"
    public let id: String
    public let method: String = "resources/read"
    public let params: ReadResourceParams
    
    public struct ReadResourceParams: Codable {
        public let uri: String
    }
    
    public init(id: String = UUID().uuidString, uri: String) {
        self.id = id
        self.params = ReadResourceParams(uri: uri)
    }
}

public struct SubscribeRequest: MCPRequest {
    public let jsonrpc: String = "2.0"
    public let id: String
    public let method: String = "resources/subscribe"
    public let params: SubscribeParams
    
    public struct SubscribeParams: Codable {
        public let uri: String
    }
    
    public init(id: String = UUID().uuidString, uri: String) {
        self.id = id
        self.params = SubscribeParams(uri: uri)
    }
}

public struct UnsubscribeRequest: MCPRequest {
    public let jsonrpc: String = "2.0"
    public let id: String
    public let method: String = "resources/unsubscribe"
    public let params: UnsubscribeParams
    
    public struct UnsubscribeParams: Codable {
        public let uri: String
    }
    
    public init(id: String = UUID().uuidString, uri: String) {
        self.id = id
        self.params = UnsubscribeParams(uri: uri)
    }
}

/// Resource response types
public struct ListResourcesResponse: MCPResponse {
    public let jsonrpc: String = "2.0"
    public let id: String
    public let result: ListResourcesResult
    
    public struct ListResourcesResult: Codable {
        public let resources: [ResourceMetadata]
    }
}

public struct ReadResourceResponse: MCPResponse {
    public let jsonrpc: String = "2.0"
    public let id: String
    public let result: ReadResourceResult
    
    public struct ReadResourceResult: Codable {
        public let content: ResourceContent
    }
}

/// Resource notification types
public struct ResourceUpdatedNotification: MCPNotification {
    public let jsonrpc: String = "2.0"
    public let method: String = "notifications/resource/updated"
    public let params: ResourceUpdatedParams
    
    public struct ResourceUpdatedParams: Codable {
        public let uri: String
        public let content: ResourceContent
    }
} 