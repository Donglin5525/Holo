import Foundation

@main
struct HoloAIUserErrorMapperStandaloneTests {
    static func main() {
        let unsafe: [Error] = [
            APIError.decodingError(NSError(domain: "deepseek-json", code: 1)),
            APIError.httpError(statusCode: 500, message: "https://api.deepseek.com model=qwen temperature=0.8"),
            APIError.serverError("provider moonshot HTTP raw body"),
            NSError(domain: "model-secret", code: 9),
        ]
        for error in unsafe {
            let message = HoloAIUserErrorMapper.message(for: error).lowercased()
            for secret in ["deepseek", "qwen", "moonshot", "http", "temperature", "provider", "json"] {
                expect(!message.contains(secret), "用户错误泄露技术细节：\(message)")
            }
        }
        expect(HoloAIUserErrorMapper.message(for: APIError.timeout).contains("超时"), "超时文案错误")
        expect(HoloAIUserErrorMapper.message(for: APIError.rateLimited(nil)).contains("上限"), "限额文案错误")
        print("HoloAIUserErrorMapperStandaloneTests: PASS")
    }

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
}
