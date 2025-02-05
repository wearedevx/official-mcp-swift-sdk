import Foundation

/// Tool metadata
public struct Tool: Codable {
    public let name: String
    public let description: String?
    public let inputSchema: [String: Any]?
    
    enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema
    }
    
    public init(name: String, description: String? = nil, inputSchema: [String: Any]? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        inputSchema = try container.decodeIfPresent([String: Any].self, forKey: .inputSchema)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        if let schema = inputSchema {
            try container.encode(schema, forKey: .inputSchema)
        }
    }
}

/// Tool request types
public struct ListToolsRequest: MCPRequest {
    public let jsonrpc: String = "2.0"
    public let id: String
    public let method: String = "tools/list"
    
    public init(id: String = UUID().uuidString) {
        self.id = id
    }
}

public struct CallToolRequest: MCPRequest {
    public let jsonrpc: String = "2.0"
    public let id: String
    public let method: String = "tools/call"
    public let params: CallToolParams
    
    public struct CallToolParams: Codable {
        public let name: String
        public let arguments: [String: Any]?
        
        enum CodingKeys: String, CodingKey {
            case name
            case arguments
        }
        
        public init(name: String, arguments: [String: Any]? = nil) {
            self.name = name
            self.arguments = arguments
        }
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            arguments = try container.decodeIfPresent([String: Any].self, forKey: .arguments)
        }
        
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            if let args = arguments {
                try container.encode(args, forKey: .arguments)
            }
        }
    }
    
    public init(id: String = UUID().uuidString, name: String, arguments: [String: Any]? = nil) {
        self.id = id
        self.params = CallToolParams(name: name, arguments: arguments)
    }
}

/// Tool response types
public struct ListToolsResponse: MCPResponse {
    public let jsonrpc: String = "2.0"
    public let id: String
    public let result: ListToolsResult
    
    public struct ListToolsResult: Codable {
        public let tools: [Tool]
    }
}

public struct CallToolResponse: MCPResponse {
    public let jsonrpc: String = "2.0"
    public let id: String
    public let result: CallToolResult
    
    public struct CallToolResult: Codable {
        public let content: [ToolContent]
        public let isError: Bool?
        
        public init(content: [ToolContent], isError: Bool? = nil) {
            self.content = content
            self.isError = isError
        }
    }
}

/// Tool content types
public enum ToolContent: Codable {
    case text(String)
    case image(ImageContent)
    
    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case image
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        
        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "image":
            let image = try container.decode(ImageContent.self, forKey: .image)
            self = .image(image)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown tool content type")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let image):
            try container.encode("image", forKey: .type)
            try container.encode(image, forKey: .image)
        }
    }
}

/// Image content type
public struct ImageContent: Codable {
    public let data: String
    public let mimeType: String
    public let metadata: [String: String]?
    
    public init(data: String, mimeType: String, metadata: [String: String]? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.metadata = metadata
    }
}

/// Tool notification types
public struct ToolListChangedNotification: MCPNotification {
    public let jsonrpc: String = "2.0"
    public let method: String = "notifications/tools/list_changed"
} 