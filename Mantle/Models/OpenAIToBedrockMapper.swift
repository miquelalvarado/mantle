import AWSBedrockRuntime

enum MappingError: Error {
    case mustStartWithUser
}

struct OpenAIToBedrockMapper {

    static func map(_ messages: [OpenAIMessage]) throws
        -> (system: [BedrockRuntimeClientTypes.SystemContentBlock],
            messages: [BedrockRuntimeClientTypes.Message])
    {
        // 1. Separate system messages
        let systemBlocks: [BedrockRuntimeClientTypes.SystemContentBlock] = messages
            .filter { $0.role == "system" }
            .map { .text(extractText(from: $0.content)) }

        // 2. Convert non-system messages to Bedrock roles
        var pairs: [(BedrockRuntimeClientTypes.ConversationRole, String)] = messages
            .filter { $0.role != "system" }
            .map { msg in
                let role: BedrockRuntimeClientTypes.ConversationRole
                switch msg.role {
                case "user":      role = .user
                case "assistant": role = .assistant
                default:          role = .user
                }
                return (role, extractText(from: msg.content))
            }

        // 3. Merge consecutive same-role messages
        var merged: [(BedrockRuntimeClientTypes.ConversationRole, String)] = []
        for (role, text) in pairs {
            if let last = merged.last, last.0 == role {
                merged[merged.count - 1] = (role, last.1 + "\n" + text)
            } else {
                merged.append((role, text))
            }
        }
        pairs = merged

        // 4. Validate starts with user
        guard pairs.first?.0 == .user else {
            throw MappingError.mustStartWithUser
        }

        let bedrockMessages: [BedrockRuntimeClientTypes.Message] = pairs.map { (role, text) in
            BedrockRuntimeClientTypes.Message(
                content: [.text(text)],
                role: role
            )
        }

        return (systemBlocks, bedrockMessages)
    }

    static func extractText(from content: OpenAIContent) -> String {
        switch content {
        case .text(let s):
            return s
        case .blocks(let blocks):
            return blocks.compactMap { $0.text }.joined()
        }
    }

    static func finishReason(from stopReason: BedrockRuntimeClientTypes.StopReason?) -> String {
        switch stopReason {
        case .maxTokens:    return "length"
        case .stopSequence: return "stop"
        default:            return "stop"
        }
    }
}
