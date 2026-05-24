import Foundation

@discardableResult
func expect(_ condition: @autoclosure () -> Bool, _ message: String) -> Bool {
    if condition() {
        return true
    }
    print("FAIL: \(message)")
    exit(1)
}

@main
struct MarkdownAttributedStringRendererStandaloneTests {
    static func main() {
        let markdown = """
        ## 习惯分析报告

        ### 事实
        * 整体完成率：24.67%
        * 正向习惯：健身完成 10 天
        """

        let rendered = MarkdownAttributedStringRenderer.parseSync(markdown) ?? AttributedString(markdown)
        let renderedText = String(rendered.characters)

        expect(!renderedText.contains("##"), "二级标题标记不应出现在渲染文本中")
        expect(!renderedText.contains("###"), "三级标题标记不应出现在渲染文本中")
        expect(!renderedText.contains("* 整体完成率"), "列表星号不应出现在渲染文本中")
        expect(renderedText.contains("习惯分析报告"), "标题文本应保留")
        expect(renderedText.contains("整体完成率：24.67%"), "列表正文应保留")

        print("MarkdownAttributedStringRendererStandaloneTests passed")
    }
}
