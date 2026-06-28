import AWSBedrockRuntime
import Foundation
import NIOCore

struct StreamMapper {
    let completionId: String
    let created: Int
    let modelId: String

    func makeSSESequence(
        bedrockEvents: AsyncThrowingStream<BedrockRuntimeClientTypes.ConverseStreamOutput, Error>,
        keepAliveInterval: Duration = .seconds(15)
    ) -> AsyncThrowingStream<ByteBuffer, Error> {
        let mapper = self
        return AsyncThrowingStream { continuation in
            Task {
                await mapper.run(
                    bedrockEvents: bedrockEvents,
                    keepAliveInterval: keepAliveInterval,
                    continuation: continuation
                )
            }
        }
    }

    private func run(
        bedrockEvents: AsyncThrowingStream<BedrockRuntimeClientTypes.ConverseStreamOutput, Error>,
        keepAliveInterval: Duration,
        continuation: AsyncThrowingStream<ByteBuffer, Error>.Continuation
    ) async {
        // 1. Role-announcement chunk
        do {
            let roleChunk = OpenAIChunk(
                id: completionId,
                object: "chat.completion.chunk",
                created: created,
                model: modelId,
                choices: [OpenAIChoice(
                    index: 0,
                    delta: OpenAIDelta(role: "assistant", content: ""),
                    finishReason: nil
                )],
                usage: nil
            )
            continuation.yield(try sseData(roleChunk))
        } catch {
            continuation.finish(throwing: error)
            return
        }

        let state = KeepAliveState()

        let keepAliveTask = Task { [state] in
            let intervalSecs = Double(keepAliveInterval.components.seconds)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                if Date().timeIntervalSince(state.lastYield) >= intervalSecs {
                    var buf = ByteBuffer()
                    buf.writeString(": keep-alive\n\n")
                    continuation.yield(buf)
                    state.lastYield = Date()
                }
            }
        }

        defer { keepAliveTask.cancel() }

        var promptTokens = 0
        var completionTokens = 0

        do {
            for try await event in bedrockEvents {
                switch event {
                case .contentblockdelta(let e):
                    if case .text(let t) = e.delta {
                        let chunk = OpenAIChunk(
                            id: completionId,
                            object: "chat.completion.chunk",
                            created: created,
                            model: modelId,
                            choices: [OpenAIChoice(
                                index: 0,
                                delta: OpenAIDelta(role: nil, content: t),
                                finishReason: nil
                            )],
                            usage: nil
                        )
                        continuation.yield(try sseData(chunk))
                        state.lastYield = Date()
                    }
                case .metadata(let e):
                    promptTokens = e.usage?.inputTokens ?? 0
                    completionTokens = e.usage?.outputTokens ?? 0
                case .messagestop(let e):
                    let finishReason = OpenAIToBedrockMapper.finishReason(from: e.stopReason)
                    let finalChunk = OpenAIChunk(
                        id: completionId,
                        object: "chat.completion.chunk",
                        created: created,
                        model: modelId,
                        choices: [OpenAIChoice(
                            index: 0,
                            delta: OpenAIDelta(role: nil, content: nil),
                            finishReason: finishReason
                        )],
                        usage: OpenAIUsage(
                            promptTokens: promptTokens,
                            completionTokens: completionTokens,
                            totalTokens: promptTokens + completionTokens
                        )
                    )
                    continuation.yield(try sseData(finalChunk))
                    state.lastYield = Date()
                    var doneBuf = ByteBuffer()
                    doneBuf.writeString("data: [DONE]\n\n")
                    continuation.yield(doneBuf)
                    continuation.finish()
                    return
                default:
                    break
                }
            }
            continuation.finish()
        } catch {
            let errResponse = OpenAIErrorResponse(
                error: OpenAIError(
                    message: error.localizedDescription,
                    type: "bedrock_error",
                    code: nil
                )
            )
            if let buf = try? sseData(errResponse) {
                continuation.yield(buf)
            }
            var doneBuf = ByteBuffer()
            doneBuf.writeString("data: [DONE]\n\n")
            continuation.yield(doneBuf)
            continuation.finish()
        }
    }

    private func sseData(_ value: some Encodable) throws -> ByteBuffer {
        let json = try JSONEncoder().encode(value)
        var buf = ByteBuffer()
        buf.writeString("data: \(String(decoding: json, as: UTF8.self))\n\n")
        return buf
    }
}

private final class KeepAliveState: @unchecked Sendable {
    var lastYield: Date = Date()
}
