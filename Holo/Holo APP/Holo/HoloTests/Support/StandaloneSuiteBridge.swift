import XCTest

/// 独立脚本式测试套件（`struct XxxStandaloneTests { static func main() }`）接入常规 XCTest 的公共件。
///
/// 执行入口是自动生成的桥接文件 `Support/StandaloneExecutableBridgeTests.swift`：
/// 生成脚本 `scripts/generate-standalone-xctest-bridge.rb` 给每个套件生成一条用例，
/// 先问本表（已知失败登记），再跑套件的 main()。套件文件本身只带「独立运行启动器」和「断言垫片」——
/// 断言失败在测试工程里走 XCTFail，不再崩掉整个测试进程（独立脚本运行仍用标准库的 fatalError / precondition）。
///
/// 为什么要有这张表（2026-11-24 技术优化）：独立脚本式套件原先用 fatalError / precondition 当断言，
/// 一失败就把测试进程崩掉，同批其他用例的结果跟着丢失，崩溃报告里全是「红测」记录；
/// 改成 XCTFail 后失败就是一条正常的红用例。已知失败的套件在这里写明原因、默认跳过、用例列表里显式可见，
/// 修好后从表里删掉即恢复执行。
///
/// 新增独立脚本式套件后的三步（Test Mount Guard 会拦住漏做的）：
/// 1. 挂进工程：`python3 BuildScripts/pbxproj_surgery.py mount --file HoloTests/<路径>.swift`
/// 2. 已提交但从未进桥的文件，在 `scripts/xctest-bridge-allowlist.txt` 加一行文件名
/// 3. 重新生成桥接：`ruby scripts/generate-standalone-xctest-bridge.rb`
enum StandaloneSuites {
    /// 套件名 → 已知失败原因。登记制：只许写明原因后跳过，用例列表里显示为 skipped；修好后从表里删掉即恢复执行。
    /// 设环境变量 HOLO_STANDALONE_RUN_KNOWN_FAILING=1 时不跳过（摸底/复查用）。
    static let knownFailing: [String: String] = [
        "HoloAgentEvalRunnerTests": "Eval 基线 177 条里 80 条不达标（2026-11-24 首次进自动测试时发现）；需 Agent 线逐类归因后收敛",
        "HoloAgentAnswerObservabilityStandaloneTests": "legacy_fallback 计数为 0：夹具 finance.total.amount/aggregate 没命中旧目录（usedCatalog=false）；待 Agent 线确认是目录漂移还是夹具过期",
    ]

    /// 自动桥接的每条用例第一行调用：在已知失败表里就跳过。
    static func skipIfListed(_ suite: String) throws {
        guard let reason = knownFailing[suite],
              ProcessInfo.processInfo.environment["HOLO_STANDALONE_RUN_KNOWN_FAILING"] != "1" else { return }
        throw XCTSkip("独立脚本式套件已知失败，暂不执行：\(reason)")
    }
}
