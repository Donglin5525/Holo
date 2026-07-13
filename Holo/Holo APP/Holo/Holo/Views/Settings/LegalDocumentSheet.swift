//
//  LegalDocumentSheet.swift
//  Holo
//
//  法律文档查看器 - 本地展示隐私政策和用户协议
//

import SwiftUI
import WebKit

// MARK: - 法律文档查看器

/// 本地法律文档查看器，无需网络即可查看
struct LegalDocumentSheet: View {

    let documentType: LegalDocumentType

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LegalWebView(htmlContent: documentType.htmlContent)
                .navigationTitle(documentType.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") {
                            dismiss()
                        }
                    }
                }
        }
    }
}

// MARK: - 文档类型

enum LegalDocumentType {
    case privacyPolicy
    case termsOfUse

    var title: String {
        switch self {
        case .privacyPolicy: return "隐私政策"
        case .termsOfUse: return "用户协议"
        }
    }

    var htmlContent: String {
        switch self {
        case .privacyPolicy: return LegalHTMLTemplates.privacyPolicy
        case .termsOfUse: return LegalHTMLTemplates.termsOfUse
        }
    }
}

// MARK: - WebView

private struct LegalWebView: UIViewRepresentable {

    let htmlContent: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(htmlContent, baseURL: nil)
    }
}

// MARK: - HTML 模板

/// 法律文档 HTML 内容，直接嵌入 App，离线可用
enum LegalHTMLTemplates {

    private static let baseCSS = """
    :root {
        --bg: #ffffff;
        --fg: #1a1a1a;
        --muted: #666666;
        --accent: #007AFF;
        --border: #e5e5e5;
    }
    @media (prefers-color-scheme: dark) {
        :root {
            --bg: #1c1c1e;
            --fg: #f5f5f7;
            --muted: #a1a1a6;
            --accent: #0a84ff;
            --border: #38383a;
        }
    }
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
        font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", "PingFang SC", sans-serif;
        background: var(--bg);
        color: var(--fg);
        line-height: 1.7;
        padding: 20px 16px;
    }
    h1 { font-size: 1.6em; margin-bottom: 8px; }
    h2 { font-size: 1.2em; margin-top: 28px; margin-bottom: 10px; color: var(--accent); border-bottom: 1px solid var(--border); padding-bottom: 6px; }
    h3 { font-size: 1.05em; margin-top: 18px; margin-bottom: 6px; }
    p { margin-bottom: 10px; }
    .meta { color: var(--muted); font-size: 0.9em; margin-bottom: 20px; }
    ul, ol { padding-left: 20px; margin-bottom: 10px; }
    li { margin-bottom: 4px; }
    table { width: 100%; border-collapse: collapse; margin: 10px 0; font-size: 0.9em; }
    th, td { border: 1px solid var(--border); padding: 8px 10px; text-align: left; }
    th { background: var(--accent); color: #fff; }
    .highlight { background: rgba(0, 122, 255, 0.08); border-radius: 6px; padding: 10px 14px; margin: 12px 0; }
    .footer { margin-top: 32px; padding-top: 12px; border-top: 1px solid var(--border); color: var(--muted); font-size: 0.85em; }
    """

    static let privacyPolicy = """
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>\(baseCSS)</style>
    </head>
    <body>

    <h1>Holo 隐私政策</h1>
    <p class="meta">最后更新日期：2026 年 6 月 7 日<br>生效日期：2026 年 6 月 7 日</p>

    <p>欢迎使用 Holo（以下简称"本应用"）。我们深知个人数据的重要性，并致力于保护您的隐私。本隐私政策旨在向您说明我们如何收集、使用、存储和保护您的信息。</p>

    <div class="highlight">
        <strong>核心原则：</strong>您的数据属于您自己。我们尽可能将数据存储在您的设备本地和您的个人 iCloud 中。我们不会出售您的个人数据，也不会将您的数据用于广告投放。
    </div>

    <h2>一、我们收集的信息</h2>

    <h3>1.1 您主动提供的信息</h3>
    <ul>
        <li><strong>账户信息</strong>：当您使用"通过 Apple 登录"时，我们会收到您的 Apple ID 关联邮箱地址和唯一用户标识符。您可以选择隐藏邮箱地址。</li>
        <li><strong>财务记录</strong>：您手动输入的记账数据，包括金额、分类、账户、日期和备注。这些数据存储在您的设备本地和您的 iCloud 中。</li>
        <li><strong>健康数据</strong>：在您授权后，本应用会从 Apple HealthKit 读取步数、睡眠、站立、运动时长等健康数据。本应用<strong>不会写入或修改</strong>您的健康数据。</li>
        <li><strong>习惯与待办</strong>：您创建的习惯追踪记录和待办事项。</li>
        <li><strong>观点记录</strong>：您创建的观点、标签和引用，存储在您的设备本地和您的 iCloud 中。</li>
        <li><strong>语音输入</strong>：当您使用语音输入功能时，音频数据会发送至我们的服务器进行语音转文字处理，处理完成后音频数据不会被保存。</li>
    </ul>

    <h3>1.2 AI 功能处理的数据</h3>
    <p>本应用提供 AI 智能助手功能（包括数据洞察、记忆分析、智能分类等）。当您使用这些功能时：</p>
    <ul>
        <li>您的问题和相关上下文数据会通过加密连接发送至我们的后端服务器。</li>
        <li>后端服务器将数据转发至第三方 AI 服务提供商进行处理。</li>
        <li>AI 服务提供商处理后返回分析结果。我们不会主动保存您发送给 AI 的原始请求正文或完整上下文作为用户资料。</li>
        <li>生成的分析结果保存在您的设备本地。</li>
    </ul>

    <h3>1.3 自动收集的信息</h3>
    <p>我们<strong>不会</strong>自动收集您的设备信息、位置信息或使用行为数据。我们不使用任何第三方分析工具。</p>

    <h2>二、信息的使用目的</h2>

    <table>
        <thead><tr><th>数据类型</th><th>使用目的</th></tr></thead>
        <tbody>
            <tr><td>Apple ID 信息</td><td>用户身份认证与登录</td></tr>
            <tr><td>财务记录</td><td>记账功能、数据统计与展示</td></tr>
            <tr><td>健康数据（只读）</td><td>健康数据展示与趋势分析</td></tr>
            <tr><td>习惯与待办数据</td><td>习惯追踪与任务管理功能</td></tr>
            <tr><td>观点数据</td><td>观点记录、标签与引用管理</td></tr>
            <tr><td>语音音频</td><td>语音转文字，用于记账或 AI 对话输入</td></tr>
            <tr><td>AI 对话上下文</td><td>生成数据分析、智能建议等 AI 功能</td></tr>
        </tbody>
    </table>

    <h2>三、数据的存储与安全</h2>

    <h3>3.1 本地存储</h3>
    <p>您的核心数据存储在您的设备本地，使用 Apple Core Data 框架进行管理。</p>
    <p>普通账号不会在设备上另存 AI 原始技术日志。仅经服务端验证的开发者内部诊断账号，可在其本人设备保存最长 7 天的完整调用日志用于排障；该日志受系统文件保护且不会同步到 iCloud，退出登录或权限失效后会被清除。</p>

    <h3>3.2 iCloud 同步</h3>
    <p>在您登录 iCloud 并启用同步后，您的 Holo 本地记录会通过 Apple CloudKit 在您的设备之间同步。数据传输和存储均受 Apple 的加密保护。我们<strong>无法访问</strong>您 iCloud 中的用户数据。Holo 不会将从 Apple HealthKit 读取的原始健康数据写入或同步到 Holo 的 iCloud 数据库。</p>

    <h3>3.3 服务器端处理</h3>
    <ul>
        <li>AI 和语音识别请求通过 HTTPS 加密传输至我们的后端服务器。</li>
        <li>服务器主要用于请求转发、限流、安全防护和故障排查。我们不会主动保存您发送给 AI 的原始请求正文、语音音频或完整上下文作为用户资料。</li>
        <li>为保障服务稳定性，服务器会保存最小化的技术日志或摘要信息，例如设备标识、调用类型、服务商、模型、耗时、错误信息、请求/响应摘要或长度以及调用时间。日志用于安全、限流和排障，默认不保存完整原文，并会按后台配置定期清理。</li>
    </ul>

    <h3>3.4 安全措施</h3>
    <ul>
        <li>所有网络通信使用 TLS 1.2+ 加密。</li>
        <li>API Key 不存储在客户端应用中，由后端服务器安全保管。</li>
        <li>服务器部署在受防火墙保护的云环境中。</li>
    </ul>

    <h2>四、信息共享</h2>
    <p>我们<strong>不会</strong>出售、出租或交易您的个人信息。</p>
    <ul>
        <li><strong>AI 服务提供商</strong>：在您使用 AI 功能并同意 AI 数据处理授权后，您的提问和必要上下文会发送至第三方 AI 服务（如阿里云百炼、DeepSeek 等）。</li>
        <li><strong>Apple 服务</strong>：Sign in with Apple 和 iCloud 同步由 Apple 提供并受 Apple 隐私政策约束。</li>
        <li><strong>法律要求</strong>：在适用法律法规要求时，我们可能需要披露您的信息。</li>
    </ul>

    <h2>五、您的权利</h2>
    <ul>
        <li><strong>访问数据</strong>：您可随时在应用内查看所有已存储的个人数据。</li>
        <li><strong>删除数据</strong>：您可以在设置中选择"删除账号与数据"。</li>
        <li><strong>撤销授权</strong>：您可以在设备"设置"→"隐私与安全性"中随时撤销各项权限。</li>
    </ul>

    <h2>六、数据保留期限</h2>
    <ul>
        <li>本地数据：在您主动删除或卸载应用前持续保留。</li>
        <li>iCloud 数据：随您的 iCloud 账户保留。</li>
        <li>服务器日志：仅保留最小化技术日志或摘要信息，用于安全、限流和排障，并按后台配置定期清理；我们不会主动保存 AI 原始请求正文、语音音频或完整上下文作为用户资料。</li>
        <li>语音音频：处理完成后立即销毁。</li>
    </ul>

    <h2>七、儿童隐私</h2>
    <p>本应用不面向 13 岁以下儿童。如果我们发现误收集了儿童的数据，将立即删除。</p>

    <h2>八、隐私政策的更新</h2>
    <p>重大变更将通过应用内通知告知您。继续使用即表示您同意更新后的政策。</p>

    <h2>九、联系我们</h2>
    <ul>
        <li>邮箱：support@holoapp.cn</li>
        <li>网站：https://holoapp.cn</li>
    </ul>

    <div class="footer">
        <p>© 2026 Holo. 保留所有权利。</p>
    </div>

    </body>
    </html>
    """

    static let termsOfUse = """
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>\(baseCSS)</style>
    </head>
    <body>

    <h1>Holo 用户协议</h1>
    <p class="meta">最后更新日期：2026 年 6 月 7 日<br>生效日期：2026 年 6 月 7 日</p>

    <p>欢迎使用 Holo 应用（以下简称"本应用"）。在使用本应用之前，请仔细阅读以下条款。下载、安装或使用本应用即表示您同意受本协议的约束。</p>

    <h2>一、协议的范围</h2>
    <p>本协议是您（以下简称"用户"）与本应用开发者之间关于使用 Holo 应用的法律协议。本协议适用于 Holo iOS 应用的所有功能。</p>

    <h2>二、账户与登录</h2>
    <ol>
        <li>本应用通过"Sign in with Apple"服务进行用户身份认证。</li>
        <li>用户应妥善保管自己的 Apple ID 凭证，因账户保管不善导致的损失由用户自行承担。</li>
        <li>用户可随时在应用设置中选择删除账号及相关数据。删除操作不可恢复。</li>
    </ol>

    <h2>三、服务内容</h2>
    <ol>
        <li><strong>核心功能</strong>：本应用提供个人数据管理工具，包括财务记录、习惯追踪、待办管理、健康数据展示和观点记录等。</li>
        <li><strong>AI 功能</strong>：本应用提供基于人工智能的数据分析和智能建议。AI 生成的内容仅供参考，不构成专业建议。</li>
        <li><strong>数据存储</strong>：用户数据主要存储在用户设备本地，可通过 iCloud 在用户自己的设备间同步。</li>
        <li>开发者保留在提前通知用户的情况下修改、暂停或终止部分服务功能的权利。</li>
    </ol>

    <h2>四、用户行为规范</h2>
    <p>用户在使用本应用时，不得：</p>
    <ul>
        <li>利用本应用从事任何违反法律法规的活动；</li>
        <li>通过技术手段破解、修改或逆向工程本应用；</li>
        <li>利用 AI 功能生成违法、有害、不实或侵犯他人权益的内容；</li>
        <li>干扰或破坏应用的正常运营。</li>
    </ul>

    <h2>五、知识产权</h2>
    <ol>
        <li>本应用的界面设计、代码、图标等所有内容的知识产权归开发者所有。</li>
        <li>用户在本应用中创建的数据的知识产权归用户所有。</li>
    </ol>

    <h2>六、免责声明</h2>

    <div class="highlight">
        <strong>重要提示：</strong>本应用提供的 AI 分析和建议仅供参考，不构成任何专业建议（包括财务、医疗、法律建议）。用户应自行判断并承担使用 AI 生成内容的全部风险。
    </div>

    <ol>
        <li><strong>AI 内容</strong>：AI 生成的内容可能存在不准确或不完整的情况，不应作为决策的唯一依据。</li>
        <li><strong>健康数据</strong>：本应用展示的健康数据来源于 Apple HealthKit，仅供个人参考。如有健康问题，请咨询专业医疗人员。</li>
        <li><strong>财务数据</strong>：本应用仅提供记账工具，不提供财务规划或投资建议。</li>
        <li><strong>数据安全</strong>：虽然本应用采用业界标准的安全措施，但任何互联网传输和电子存储都无法保证绝对安全。</li>
    </ol>

    <h2>七、数据与隐私</h2>
    <p>关于数据的收集、使用、存储和共享，请参阅本应用的《隐私政策》。隐私政策是本协议不可分割的一部分。</p>

    <h2>八、协议的变更</h2>
    <ol>
        <li>开发者保留随时修改本协议的权利。</li>
        <li>重大变更将通过应用内通知告知用户。</li>
        <li>用户在协议变更后继续使用本应用，即视为同意修改后的协议。</li>
    </ol>

    <h2>九、终止</h2>
    <ol>
        <li>用户可随时停止使用本应用并通过应用设置删除账号。</li>
        <li>如用户严重违反本协议，开发者有权终止向该用户提供服务。</li>
    </ol>

    <h2>十、适用法律与争议解决</h2>
    <ol>
        <li>本协议适用中华人民共和国法律。</li>
        <li>因本协议产生的争议，双方应首先通过友好协商解决。协商不成的，任何一方可向开发者所在地有管辖权的人民法院提起诉讼。</li>
    </ol>

    <h2>十一、联系方式</h2>
    <ul>
        <li>邮箱：support@holoapp.cn</li>
        <li>网站：https://holoapp.cn</li>
    </ul>

    <div class="footer">
        <p>© 2026 Holo. 保留所有权利。</p>
    </div>

    </body>
    </html>
    """
}
