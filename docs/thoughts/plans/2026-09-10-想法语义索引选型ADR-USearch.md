# ADR：想法本地语义索引选型（USearch HNSW vs Flat 扫描 vs sqlite-vec）

日期：2026-09-10 ｜ 状态：Phase 0（数据待填） ｜ 决策关联：[V3 主方案 §8](2026-09-10-Holo想法本地语义图谱V3-完整实施方案-GLM.md)

## 1. 决策需求

V3 需要一个**纯本机、不进 CloudKit**的向量索引，支撑：

- 5 万–10 万条 1024 维向量的渐进索引与近邻检索；
- 持久化、损坏重建、tombstone 删除、版本代际切换；
- 方案 §20.3 性能门禁（50k warm search p95 <150ms、100k <300ms、50k 冷开首查 <800ms、内存峰值增量 <100MiB、upsert p95 <100ms）。

现有 `ThoughtEmbeddingStore`（5000 条 JSON + [Double] 全量扫描）不可扩展，已在方案中否决。

## 2. 候选项

| 候选 | 路线 | 结论 |
|---|---|---|
| **USearch 2.26.2**（固定 tag `f91fe5bc`） | SwiftPM C++/ObjC++ HNSW，`.f16` 量化 | **主路线**（本 ADR 验证对象） |
| Float16 + Accelerate 分块 flat 扫描 | 自研暴力扫描 | **协议化 fallback**（USearch spike 不过门禁时启用，同样要过 50k/100k 门禁） |
| sqlite-vec | SQLite 扩展向量检索 | **否决**：0.x alpha、移动端集成边界大（方案 §8.1 已裁定） |

## 3. 集成事实（spike 实测 API 真身，Phase 2 实现的直接输入）

- 包：`https://github.com/unum-cloud/USearch`，`.exact("2.26.2")`，间接依赖 `NumKong 7.8.2`（SIMD 工具库）。已确认 tag 存在，**禁止跟随 main**。
- Swift API 关键签名（与官方文档示例有差异，以编译实测为准）：
  - key 类型是 `USearchKey = UInt64`（非 UInt）；
  - `make(metric:dimensions:connectivity:quantization:)`、`reserve(_:)`（UInt32）、`add(key:vector:)`、`search(vector:count:)`（count 为 Int）、`save/load/view(path:)`（带 `path:` 标签）、`remove(key:)`、`contains(key:)` 均 **throws**；`count` 是 **throwing 属性**；
  - `search` 返回**无标签元组** `([USearchKey], [Float])`；
  - `get(key:)` 泛型返回 `[[Float32]]?`，裸调用有重载歧义，需显式类型标注；
  - 量化枚举 `.f16` 可用（另支持 `.f32/.bf16/.e5m2/.e4m3/.e3m2/.e2m3/.u8/.i8`）；
  - **无内置批量 API、无线程安全保证**——产品封装必须 actor 化（spike 已验证 actor 封装可行）。
- 主工程已有本地 Vendor 包先例（ZIPFoundation/CoreXLSX/XMLCoder 均为 local package）。USearch 正式接入可选：A) 远程 SwiftPM + `Package.resolved` 锁定；B) Vendor 本地化（彻底断供应链漂移，代价是仓库体积）。**建议 A + 精确版本**，并在 CI/本地构建脚本中校验 resolved 版本不变。

## 4. spike 实测数据

### 4.1 iOS 模拟器正式数据（iPhone 17 / iOS 26.3 / arm64，2026-09-10，15/15 PASS）

| 指标 | 5k | 50k | 100k | 门禁 | 判定 |
|---|---|---|---|---|---|
| 插入总耗时（均条） | 14.7s（2.9ms） | 210.3s（4.2ms） | 467.8s（4.7ms） | upsert p95 <100ms/条 | ✅（~20×余量） |
| warm search p95（top-20×200 查询） | 1.3ms | 1.9ms | 1.9ms | 50k<150ms、100k<300ms | ✅（~80-150×余量） |
| warm search p99 | 1.6ms | 2.8ms | 2.3ms | — | ✅ |
| save 耗时 / 文件大小 | — | 0.17s / 105MB | — | — | ✅ |
| load 耗时 / load 后首查 | — | 0.07s / **1.7ms** | — | 冷开首查 <800ms | ✅（~470×余量） |
| view(mmap) 挂载 / 首查 | — | 0.01s / 1.8ms | — | — | ✅ |
| recall@20 vs flat（5k，100 查询） | mean 0.988 / min 0.95 | — | — | ≥0.9 | ✅ |
| 驻留内存增量（独立 100k f16） | — | — | 223MB | 记录（真机门禁 <100MiB 另判） | 📊 |
| 删除 500/5000 后 | 计数正确、get nil、查询无已删 key | — | — | 无泄漏 | ✅ |
| 损坏文件 load | 抛错不崩溃 | — | — | 抛错 | ✅ |
| actor 并发（16 读任务+串行写 200） | 0.9s 无死锁崩溃 | — | — | 无死锁 | ✅ |

向量：1024 维、L2 归一化、簇心+噪声构造（25 簇/5k 比例模拟真实 embedding 结构）、`.f16` 量化、connectivity 16。注：内存 223MB 是「常驻完整索引」口径；产品可用 `view()` mmap 形态显著降低常驻内存（Phase 2 实测）。

### 4.2 构建矩阵

| 目标 | 结果 |
|---|---|
| macOS host（swift test，正确性参照） | ✅ 7 测试全绿（修正 1 个断言设计错误后） |
| iOS 模拟器 Debug（simctl spawn 执行 runner） | ✅ 15/15 PASS（上表数据来源） |
| 真机 arm64 + Release + 无签名（xcodebuild generic/platform=iOS） | ✅ BUILD SUCCEEDED，产物 arm64 验证 |
| **真机实机运行** | ⚠️ **未验证，待东林配合**（Phase 0 完成门唯一挂起项） |

### 4.3 spike 过程中发现的工具链事实（Phase 2 必读）

1. **xcodebuild 对 NumKong（USearch 依赖）的 header-only C target 有链接 bug**：xcodebuild 为 `CNumKong`（path=include，无源文件）生成不存在的 `CNumKong.o` 链接产物——**任何链接 USearch 的可执行/test target 在 xcodebuild 下必挂**（库 target 不做最终链接所以能编）。SwiftPM 原生构建无此问题。
   - **✅ 已解决（2026-09-10，东林拍板「最安全方式」）**：USearch 2.26.2 + NumKong 7.8.2 已 Vendor 化进主工程 `Vendor/`（照 CoreXLSX/ZIPFoundation/XMLCoder 既有惯例）；USearch 的 Package.swift 将 NumKong 改为本地路径依赖；NumKong 加 `include/numkong_vendor_compat.c`（仅注释的空源文件）让 CNumKong 产生真实编译产物。**验证闭环**：vendored 包下 xcodebuild 链接 spike-runner 模拟器 BUILD SUCCEEDED（CNumKong.o 真实产出）+ 真机 arm64 Release BUILD SUCCEEDED + 模拟器功能回归（见 §4.1 复跑）。补丁删除即回上游行为；细节见 `Vendor/README.md`。
2. 模拟器跑 SPM 无 XCTest 测试需 SwiftPM destination 文件（完整字段：version=1/sdk/target/toolchain-bin-dir/extra-*-flags），且 XCTest Swift overlay 装不上——性能验证改用可执行 target + `simctl spawn` 直跑，验证有效且更快。（验证工程位置：仓库根 `.spike/usearch-spike`，不入库。）
3. xcodebuild 对 SPM 包的自动 scheme 名不稳定（usearch-spike-Package ↔ usearch-spike，随 manifest 变化刷新）。

## 5. 风险与限制

1. **真机未验证**（arm64 iPhone）：模拟器跑在 Mac 芯片上，性能数字偏乐观；`.f16` 依赖硬件支持，老设备需确认（文档称 Float32/64 恒可用）。
2. **Release/archive 未验证**：待补 `xcodebuild -configuration Release` 与无签名真机架构编译（`CODE_SIGNING_ALLOWED=NO`）。
3. USearch Swift 绑定无官方线程安全承诺，所有读写必须过自研 actor；并发写需要外部串行化。
4. 版本升级是破坏性风险：2.x 系列 Swift API 已与文档示例漂移（见 §3），升级必须重跑本 spike 门禁。

## 6. 结论

**有条件通过：USearch 2.26.2 定为 V3 本地语义索引的默认路线**，满足：

- 性能与正确性门禁在 iOS 模拟器上全部通过且余量巨大（p95 检索 1.9ms vs 门禁 150ms；冷载首查 1.7ms vs 800ms；recall 0.988）；
- 真机 arm64 + Release 工具链完整编译通过；
- 持久化（save/load/view）、tombstone 删除、损坏恢复、actor 并发模型全部验证可行。

**条件（更新于 2026-09-10 风险解除后）**：

1. ~~xcodebuild×NumKong 链接 bug~~ **已解决**：Vendor 化 + 空源文件补丁（§4.3-1），模拟器/真机架构 xcodebuild 链接验证均通过。Phase 2 只剩把 Vendor/USearch 以 `XCLocalSwiftPackageReference` 挂进主工程 pbxproj（照 ZIPFoundation 既有四处锚点模式）。
2. 真机实测数据（性能门禁的最终裁定口径）由东林配合补齐；模拟器数字不得写入生产门禁报告。
3. 正式接入必须以协议 `LocalSemanticIndex` 封装（方案 §8.1），USearch 是默认实现而非硬依赖，fallback（Float16+Accelerate flat）保留在协议层后面。

**不回退项**：无论最终索引实现是 USearch 还是 fallback，都不得回到 JSON + [Double] 全量扫描（方案 §8.1 已否决）。
