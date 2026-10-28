import Foundation
import XCTest
@testable import MoonlitCore

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard let url = Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: base, withExtension: ext) else {
            throw XCTSkip("找不到测试数据 \(name)")
        }
        return try Data(contentsOf: url)
    }
}

/// 固定计数：每个字符算 1 个 token，便于精确断言预算。
struct CharCounter: TokenCounter {
    func count(_ text: String) -> Int { text.count }
}

func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("moonlit-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func chat(with texts: [(MessageRole, String)], characterID: UUID = UUID(), name: String = "艾琳") -> ChatSession {
    var session = ChatSession(title: "t", characterIDs: [characterID])
    for (role, text) in texts {
        session.append(ChatMessage(role: role, speakerID: role == .assistant ? characterID : nil,
                                   speakerName: role == .assistant ? name : "旅人", content: text))
    }
    return session
}
