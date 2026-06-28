import AWSBedrockRuntime
import Foundation
import Hummingbird
import NIOCore

struct ChatHandler {
    let settings: SettingsStore
    let bedrock: BedrockService

    func register(on router: some RouterMethods<some RequestContext>) {
        router.post("/v1/chat/completions", use: handle)
    }

    private func handle(request: Request, context: some RequestContext) async throws -> Response {
        // 1. Collect body
        let buffer = try await request.body.collect(upTo: 1_048_576)
        let data = Data(buffer: buffer)

        // 2. Decode request
        let chatRequest: OpenAIChatRequest
        do {
            chatRequest = try JSONDecoder().decode(OpenAIChatRequest.self, from: data)
        } catch {
            return errorResponse(status: .badRequest, message: "Invalid request body: \(error.localizedDescription)", type: "invalid_request_error", code: "invalid_json")
        }

        // 3. Reject tools
        if chatRequest.tools != nil {
            return errorResponse(status: .notImplemented, message: "Tool use not supported", type: "not_implemented", code: "tools_not_supported")
        }

        // 4. Map messages
        let (systemBlocks, bedrockMessages): ([BedrockRuntimeClientTypes.SystemContentBlock], [BedrockRuntimeClientTypes.Message])
        do {
            (systemBlocks, bedrockMessages) = try OpenAIToBedrockMapper.map(chatRequest.messages)
        } catch {
            return errorResponse(status: .badRequest, message: "Message mapping error: \(error.localizedDescription)", type: "invalid_request_error", code: "invalid_messages")
        }

        // 5. Snapshot settings on MainActor
        let (defaultModel, region, profile) = await MainActor.run {
            (settings.defaultModel, settings.region, settings.profile)
        }

        // 6. Ensure Bedrock client
        try await bedrock.ensureClient(region: region, profile: profile)

        // 7. Build Bedrock input
        let input = ConverseStreamInput(
            messages: bedrockMessages,
            modelId: defaultModel,
            system: systemBlocks.isEmpty ? nil : systemBlocks
        )

        // 8. Get stream
        let bedrockStream = try await bedrock.stream(input: input)

        // 9. Create StreamMapper
        let mapper = StreamMapper(
            completionId: "chatcmpl-\(UUID().uuidString)",
            created: Int(Date().timeIntervalSince1970),
            modelId: defaultModel
        )

        // 10. Log
        Task {
            await LogStore.shared.append(LogEntry(
                date: Date(),
                level: .info,
                text: "POST /v1/chat/completions → \(defaultModel)"
            ))
        }

        // 11. Return SSE response
        let sseHeaders: HTTPFields = [
            .contentType: "text/event-stream",
            .cacheControl: "no-cache",
            .connection: "keep-alive"
        ]

        let sseSequence = mapper.makeSSESequence(bedrockEvents: bedrockStream) { prompt, completion in
            Task {
                await LogStore.shared.append(LogEntry(
                    date: Date(),
                    level: .info,
                    text: "tokens prompt=\(prompt) completion=\(completion)"
                ))
            }
        }
        return Response(
            status: .ok,
            headers: sseHeaders,
            body: .init(asyncSequence: sseSequence)
        )
    }

    private func errorResponse(status: HTTPResponse.Status, message: String, type: String, code: String) -> Response {
        let errBody = OpenAIErrorResponse(error: OpenAIError(message: message, type: type, code: code))
        let json = (try? JSONEncoder().encode(errBody)) ?? Data()
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(data: json))
        )
    }
}
