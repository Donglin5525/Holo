# Holo 测试指南

## 测试层级

- Web：`npm test && npm run lint && npm run build`
- Backend：`npm test --prefix HoloBackend`
- XCTest：Xcode 的 `HoloTests` Target，必须真正执行测试，`build-for-testing` 不算通过。
- Standalone：纯逻辑测试可保留 `@main` 入口，由 `scripts/run-standalone-tests.rb` 统一运行并生成 XCTest bridge。

## 防遗漏门禁

```bash
ruby scripts/generate-standalone-xctest-bridge.rb
ruby scripts/sync-xctest-target.rb
ruby scripts/check-test-inventory.rb
ruby scripts/run-standalone-tests.rb
```

新增 `import XCTest` 文件必须进入 HoloTests Target；新增 standalone 文件必须被自动发现或在 manifest 中明确说明排除原因。输出 `Executed 0 tests` 视为失败。

## 环境故障判断

若 Xcode 在未编译改动文件前因 `simdiskimaged`、缺少 Simulator runtime、AssetCatalog 或 macro plugin 失败，应记录为宿主机阻塞，并补充可执行的 targeted typecheck/standalone 证据；不能把该构建失败伪装成测试通过。
