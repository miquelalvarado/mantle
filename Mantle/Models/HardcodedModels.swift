enum HardcodedModels {
    static let all: [OpenAIModel] = [
        OpenAIModel(id: "anthropic.claude-3-5-sonnet-20241022-v2:0",   object: "model", ownedBy: "anthropic"),
        OpenAIModel(id: "anthropic.claude-3-5-haiku-20241022-v1:0",    object: "model", ownedBy: "anthropic"),
        OpenAIModel(id: "anthropic.claude-3-haiku-20240307-v1:0",      object: "model", ownedBy: "anthropic"),
        OpenAIModel(id: "anthropic.claude-3-opus-20240229-v1:0",       object: "model", ownedBy: "anthropic"),
        OpenAIModel(id: "amazon.nova-pro-v1:0",                        object: "model", ownedBy: "amazon"),
        OpenAIModel(id: "amazon.nova-lite-v1:0",                       object: "model", ownedBy: "amazon"),
    ]
}
