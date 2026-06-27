import Foundation

// MARK: - Request

struct OpenAIChatRequest: Codable, Sendable {
    let model: String
    let messages: [OpenAIMessage]
    let stream: Bool?
    let maxTokens: Int?
    let temperature: Double?
    let topP: Double?
    let tools: [AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature, tools
        case maxTokens  = "max_tokens"
        case topP       = "top_p"
    }
}

struct OpenAIMessage: Codable, Sendable {
    let role: String
    let content: OpenAIContent
}

enum OpenAIContent: Codable, Sendable {
    case text(String)
    case blocks([OpenAIContentBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .text(string)
        } else {
            self = .blocks(try container.decode([OpenAIContentBlock].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let s):      try container.encode(s)
        case .blocks(let arr):  try container.encode(arr)
        }
    }
}

struct OpenAIContentBlock: Codable, Sendable {
    let type: String
    let text: String?
}

// Minimal wrapper so `tools` can be decoded without a concrete type.
struct AnyCodable: Codable, Sendable {
    init(from decoder: Decoder) throws {
        _ = try decoder.singleValueContainer()
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encodeNil()
    }
}

// MARK: - Response chunks

struct OpenAIChunk: Codable, Sendable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [OpenAIChoice]
    let usage: OpenAIUsage?
}

struct OpenAIChoice: Codable, Sendable {
    let index: Int
    let delta: OpenAIDelta
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index, delta
        case finishReason = "finish_reason"
    }
}

struct OpenAIDelta: Codable, Sendable {
    let role: String?
    let content: String?
}

struct OpenAIUsage: Codable, Sendable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens     = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens      = "total_tokens"
    }
}

// MARK: - Models list

struct OpenAIModel: Codable, Sendable {
    let id: String
    let object: String
    let ownedBy: String

    enum CodingKeys: String, CodingKey {
        case id, object
        case ownedBy = "owned_by"
    }
}

struct OpenAIModelList: Codable, Sendable {
    let object: String
    let data: [OpenAIModel]
}

// MARK: - Error

struct OpenAIErrorResponse: Codable, Sendable {
    let error: OpenAIError
}

struct OpenAIError: Codable, Sendable {
    let message: String
    let type: String
    let code: String?
}
