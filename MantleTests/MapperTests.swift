import XCTest
@testable import Mantle
import AWSBedrockRuntime
import NIOCore

final class MapperTests: XCTestCase {

    // MARK: - 6.1 System message separation

    func testSystemMessageIsSeparated() throws {
        let messages: [OpenAIMessage] = [
            OpenAIMessage(role: "system",    content: .text("Be helpful")),
            OpenAIMessage(role: "user",      content: .text("Hello")),
        ]
        let (system, conversation) = try OpenAIToBedrockMapper.map(messages)
        XCTAssertEqual(system.count, 1)
        if case .text(let t) = system[0] { XCTAssertEqual(t, "Be helpful") }
        else { XCTFail("Expected .text system block") }
        XCTAssertEqual(conversation.count, 1)
        XCTAssertEqual(conversation[0].role, .user)
    }

    // MARK: - 6.2 Consecutive same-role messages merged

    func testConsecutiveUserMessagesMerged() throws {
        let messages: [OpenAIMessage] = [
            OpenAIMessage(role: "user", content: .text("First")),
            OpenAIMessage(role: "user", content: .text("Second")),
        ]
        let (_, conversation) = try OpenAIToBedrockMapper.map(messages)
        XCTAssertEqual(conversation.count, 1)
        if case .text(let t) = conversation[0].content?.first {
            XCTAssertEqual(t, "First\nSecond")
        } else {
            XCTFail("Expected merged .text content block")
        }
    }

    func testFirstMessageAssistantThrows() {
        let messages: [OpenAIMessage] = [
            OpenAIMessage(role: "assistant", content: .text("Hello")),
        ]
        XCTAssertThrowsError(try OpenAIToBedrockMapper.map(messages)) { error in
            XCTAssertEqual(error as? MappingError, .mustStartWithUser)
        }
    }

    // MARK: - OpenAIContent extractText

    func testExtractTextFromPlainString() {
        let content = OpenAIContent.text("hello")
        XCTAssertEqual(OpenAIToBedrockMapper.extractText(from: content), "hello")
    }

    func testExtractTextFromBlocks() {
        let content = OpenAIContent.blocks([
            OpenAIContentBlock(type: "text", text: "hello"),
        ])
        XCTAssertEqual(OpenAIToBedrockMapper.extractText(from: content), "hello")
    }

    func testDecodeContentAsString() throws {
        let json = #""hello""#.data(using: .utf8)!
        let content = try JSONDecoder().decode(OpenAIContent.self, from: json)
        XCTAssertEqual(OpenAIToBedrockMapper.extractText(from: content), "hello")
    }

    func testDecodeContentAsBlockArray() throws {
        let json = #"[{"type":"text","text":"hello"}]"#.data(using: .utf8)!
        let content = try JSONDecoder().decode(OpenAIContent.self, from: json)
        XCTAssertEqual(OpenAIToBedrockMapper.extractText(from: content), "hello")
    }
}

// MARK: - 6.3 StreamMapper with canned events

final class StreamMapperTests: XCTestCase {

    private func makeStream(
        events: [BedrockRuntimeClientTypes.ConverseStreamOutput]
    ) -> AsyncThrowingStream<BedrockRuntimeClientTypes.ConverseStreamOutput, Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    private func collectSSE(
        events: [BedrockRuntimeClientTypes.ConverseStreamOutput]
    ) async throws -> [String] {
        let mapper = StreamMapper(
            completionId: "chatcmpl-test",
            created: 1000,
            modelId: "test-model"
        )
        let sseStream = mapper.makeSSESequence(bedrockEvents: makeStream(events: events))
        var results: [String] = []
        for try await buf in sseStream {
            var copy = buf
            if let str = copy.readString(length: copy.readableBytes) {
                results.append(str)
            }
        }
        return results
    }

    func testStreamMapperFullFlow() async throws {
        let events: [BedrockRuntimeClientTypes.ConverseStreamOutput] = [
            .contentblockdelta(.init(
                contentBlockIndex: 0,
                delta: .text("hello ")
            )),
            .contentblockdelta(.init(
                contentBlockIndex: 0,
                delta: .text("world")
            )),
            .metadata(.init(
                usage: .init(inputTokens: 10, outputTokens: 5)
            )),
            .messagestop(.init(
                additionalModelResponseFields: nil,
                stopReason: .endTurn
            )),
        ]

        let chunks = try await collectSSE(events: events)

        // First chunk must be role announcement
        let roleChunk = chunks[0]
        XCTAssertTrue(roleChunk.hasPrefix("data: "))
        let roleData = try XCTUnwrap(roleChunk.dropPrefix("data: ").dropSuffix("\n\n").data(using: .utf8))
        let roleDecoded = try JSONDecoder().decode(OpenAIChunk.self, from: roleData)
        XCTAssertEqual(roleDecoded.choices.first?.delta.role, "assistant")
        XCTAssertEqual(roleDecoded.choices.first?.delta.content, "")

        // Content chunks
        let textChunks = chunks.filter { $0.hasPrefix("data: {") && !$0.contains("finish_reason") }
        let contentTokens = try textChunks.compactMap { line -> String? in
            let data = try XCTUnwrap(line.dropPrefix("data: ").dropSuffix("\n\n").data(using: .utf8))
            let chunk = try JSONDecoder().decode(OpenAIChunk.self, from: data)
            return chunk.choices.first?.delta.content
        }.filter { !$0.isEmpty }
        XCTAssertEqual(contentTokens, ["hello ", "world"])

        // Final chunk has finish_reason and usage
        let finalLine = try XCTUnwrap(chunks.last(where: { $0.hasPrefix("data: {") }))
        let finalData = try XCTUnwrap(finalLine.dropPrefix("data: ").dropSuffix("\n\n").data(using: .utf8))
        let finalChunk = try JSONDecoder().decode(OpenAIChunk.self, from: finalData)
        XCTAssertEqual(finalChunk.choices.first?.finishReason, "stop")
        XCTAssertEqual(finalChunk.usage?.promptTokens, 10)
        XCTAssertEqual(finalChunk.usage?.completionTokens, 5)
        XCTAssertEqual(finalChunk.usage?.totalTokens, 15)

        // Last item is [DONE]
        XCTAssertEqual(chunks.last, "data: [DONE]\n\n")
    }

    // MARK: - 6.4 Keep-alive emitted during silence

    func testKeepAliveEmittedDuringSilence() async throws {
        // Stream that pauses 2 s before yielding the stop event; keep-alive interval = 1 s
        let stream = AsyncThrowingStream<BedrockRuntimeClientTypes.ConverseStreamOutput, Error> { continuation in
            Task {
                try await Task.sleep(for: .seconds(2))
                continuation.yield(.messagestop(.init(
                    additionalModelResponseFields: nil,
                    stopReason: .endTurn
                )))
                continuation.finish()
            }
        }

        let mapper = StreamMapper(
            completionId: "chatcmpl-ka",
            created: 1000,
            modelId: "test-model"
        )
        let sseStream = mapper.makeSSESequence(
            bedrockEvents: stream,
            keepAliveInterval: .seconds(1)
        )

        var didReceiveKeepAlive = false
        for try await buf in sseStream {
            var copy = buf
            if let str = copy.readString(length: copy.readableBytes),
               str == ": keep-alive\n\n" {
                didReceiveKeepAlive = true
                break
            }
        }
        XCTAssertTrue(didReceiveKeepAlive, "Expected at least one keep-alive before first event")
    }

    // MARK: - 6.6 Mid-flight error yields error SSE then [DONE]

    func testMidFlightErrorYieldsErrorSSEAndDone() async throws {
        enum TestError: Error { case boom }

        let stream = AsyncThrowingStream<BedrockRuntimeClientTypes.ConverseStreamOutput, Error> { continuation in
            continuation.yield(.contentblockdelta(.init(
                contentBlockIndex: 0,
                delta: .text("hi")
            )))
            continuation.finish(throwing: TestError.boom)
        }

        let mapper = StreamMapper(
            completionId: "chatcmpl-err",
            created: 1000,
            modelId: "test-model"
        )
        let sseStream = mapper.makeSSESequence(bedrockEvents: stream)

        var chunks: [String] = []
        // Must not throw — errors are encoded into SSE, not rethrown
        for try await buf in sseStream {
            var copy = buf
            if let str = copy.readString(length: copy.readableBytes) {
                chunks.append(str)
            }
        }

        // Last two chunks: error payload + [DONE]
        XCTAssertEqual(chunks.last, "data: [DONE]\n\n")
        let errorLine = try XCTUnwrap(chunks.dropLast().last)
        XCTAssertTrue(errorLine.hasPrefix("data: "), "Expected error SSE chunk before [DONE]")
        let errorData = try XCTUnwrap(errorLine.dropPrefix("data: ").dropSuffix("\n\n").data(using: .utf8))
        let errorResponse = try JSONDecoder().decode(OpenAIErrorResponse.self, from: errorData)
        XCTAssertFalse(errorResponse.error.message.isEmpty)
    }
}

// MARK: - 6.5 ProxyServer port conflict

final class ProxyServerTests: XCTestCase {

    func testPortInUseErrorSurfaced() async throws {
        let settings = SettingsStore()
        let serverA = ProxyServer(settings: settings)
        try await serverA.start()
        defer { Task { await serverA.stop() } }

        // Second server on the same port should fail with portInUse
        let serverB = ProxyServer(settings: settings)
        do {
            try await serverB.start()
            XCTFail("Expected portInUse error")
        } catch ProxyError.portInUse(let p) {
            let expectedPort = await settings.port
            XCTAssertEqual(p, expectedPort)
        } catch {
            // If the error isn't portInUse, print it so we can diagnose
            XCTFail("Expected ProxyError.portInUse, got \(type(of: error)): \(error)")
        }
        await serverB.stop()
    }
}

// MARK: - 6.7 BedrockService client recreation

final class BedrockServiceTests: XCTestCase {

    func testClientRecreatedOnRegionChange() async throws {
        let service = BedrockService()
        // First call — creates client for us-east-1
        try await service.ensureClient(region: "us-east-1", profile: "default")
        let id1 = await service.clientObjectId

        // Second call with same args — must NOT recreate
        try await service.ensureClient(region: "us-east-1", profile: "default")
        let id2 = await service.clientObjectId
        XCTAssertEqual(id1, id2, "Client should not be recreated for same region/profile")

        // Third call with different region — must recreate
        try await service.ensureClient(region: "us-west-2", profile: "default")
        let id3 = await service.clientObjectId
        XCTAssertNotEqual(id1, id3, "Client must be recreated when region changes")
    }
}

// MARK: - Helpers

private extension String {
    func dropPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
    func dropSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
