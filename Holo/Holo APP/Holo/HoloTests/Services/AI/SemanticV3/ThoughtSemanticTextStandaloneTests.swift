import Foundation
@main struct ThoughtSemanticTextStandaloneTests {
    static func main() {
        let text = String(repeating: "😀中文é\n", count: 1600)
        let chunks = ThoughtSemanticText.chunks(text, maxUTF16: 2000)
        precondition(chunks.count > 1 && chunks.map(\.text).joined() == text)
        var offset = 0
        for chunk in chunks { precondition(chunk.text.utf16.count <= 2000 && chunk.offsetUTF16 == offset); offset += chunk.text.utf16.count }
        precondition(ThoughtSemanticText.quoteMatches("中文", text:"😀中文",range:[2,4]))
        precondition(!ThoughtSemanticText.quoteMatches("😀", text:"😀中文",range:[0,1]))
        precondition(!ThoughtSemanticText.quoteMatches("中文", text:"😀中文",range:[-1,4]))
        let defaults = UserDefaults(suiteName: "holo-thought-settings-test-\(UUID())")!
        precondition(ThoughtSemanticFeatureFlags.enabled(ThoughtSemanticFeatureFlags.automaticKey,in:defaults))
        precondition(ThoughtSemanticFeatureFlags.enabled(ThoughtSemanticFeatureFlags.newTopicsKey,in:defaults))
        precondition(ThoughtSemanticFeatureFlags.enabled(ThoughtSemanticFeatureFlags.relatedKey,in:defaults))
        defaults.set(false,forKey:"isThoughtAutoOrganizationEnabled")
        precondition(!ThoughtSemanticFeatureFlags.enabled(ThoughtSemanticFeatureFlags.automaticKey,in:defaults))
        defaults.set(false,forKey:ThoughtSemanticFeatureFlags.automaticKey)
        precondition(!ThoughtSemanticFeatureFlags.enabled(ThoughtSemanticFeatureFlags.automaticKey,in:defaults))
        print("PASS: 长正文完整分段、emoji UTF16 边界、全部默认开启与持久关闭")
    }
}
