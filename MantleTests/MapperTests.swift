import XCTest
@testable import Mantle
import AWSBedrockRuntime

final class MapperTests: XCTestCase {

    // MARK: - OpenAIToBedrockMapper

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

    // MARK: - OpenAIContent Codable

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
