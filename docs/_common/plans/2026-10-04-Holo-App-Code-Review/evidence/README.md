# Code Review 证据说明

本目录对应 2026-10-04 09:56 冻结快照，主报告为同级上方的 Holo-App-Code-Review.md。全部业务结论需对应代码哈希和报告证据等级；本目录不是“所有问题都已修复”的证明。

## 证据分类

| 文件 | 用途 |
| --- | --- |
| manifest.json | 本轮源码/工程的相对路径、SHA-256、大小与行数；路径相对 HOLO 仓库 |
| build-diagnostics.txt / summary-initial.json | 第一份快照编译错误和扫描元信息，只用于保留审查过程 |
| build-result-final.json / build-diagnostics-final.txt | 第二份快照 Release generic Simulator unsigned build 成功与诊断；未运行 App |
| semantic-tests.log | 现有语义库正常路径 standalone 通过 |
| context-tests.log | ContextExtraction 60 断言通过；ExtractorOrchestrator 正常路径断言未通过 |
| SemanticEdgeProbe.swift / semantic-*.log | 直接编译生产 store，以临时库测试打开失败、负维度、短 BLOB |
| FusionDuplicateProbe.swift / fusion-duplicate.log | 用合成有效记录直接调用生产候选 builder；最终探针不修改功能开关 |
| ScalarEdgeProbe.swift / integer-overflow.log / dst-day.log | 单独复现生产相同的整数转换表达式和日期算法，不是 App 端到端测试 |
| CoreDataModelProbe.swift / model-migration.log | 程序化模型增加一个可选字段的独立迁移实验，不是 Holo 历史库升级 |
| results.json | 初轮异常输入退出码；最终精简重复锚点探针再次确认 SIGTRAP |
| review-metadata.json | 最终报告元数据、证据边界和快照后的已知变化 |

## 复现

使用 Xcode 自带 swiftc 和 macOS 系统框架。支持脚本只编译探针、创建临时测试数据和输出日志，不安装 App，不访问真实 App 数据库，不请求后端，不调整系统配置。

```bash
python3 '/Users/tangyuxuan/Desktop/Claude/HOLO/docs/_common/plans/2026-10-04-Holo-App-Code-Review/evidence/reproduce-probes.py'
```

默认读取主工作区的最新业务源码，因此代码更新后可能和冻结快照结果不同。可将另一份 HOLO 仓库根目录作为第一个参数。每次输出进入新建临时目录；全部 probe 按独立子进程运行，即使某个 case 故意触发 SIGTRAP，脚本仍继续记录后面的 case。

**说明：** ScalarEdgeProbe 保留的是审查时的旧表达式；即使业务代码已修复，该表达式仍会触发整数 trap。它用于解释机制，不能作为修复验收。修复时应新增调用真正验证器/仓库入口的正常和非法输入用例。程序化模型实验也不能替代真实 Holo 升级测试。

现有测试的复查命令（读取当前工作区，可能与冻结版本不同）：

```bash
bash '/Users/tangyuxuan/Desktop/Claude/HOLO/scripts/run-thought-semantic-store-standalone.sh'
bash '/Users/tangyuxuan/Desktop/Claude/HOLO/scripts/run-personal-context-standalone.sh' ContextExtraction
bash '/Users/tangyuxuan/Desktop/Claude/HOLO/scripts/run-personal-context-standalone.sh' ExtractorOrchestrator
```

## 构建基线

本轮 Release 构建在独立快照完成，未修改主工程和签名：

```bash
xcodebuild -project '/tmp/holo-code-review-20261004/Holo/Holo APP/Holo/Holo.xcodeproj' -scheme Holo -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath '/tmp/holo-code-review-20261004/DerivedData' CODE_SIGNING_ALLOWED=NO build
```

临时快照可能被清理；持久化构建诊断和源码哈希保留在本目录。本轮没有全量 XCTest、真机/模拟器 UI、双设备 CloudKit、HealthKit 实测或后端生产结论。
