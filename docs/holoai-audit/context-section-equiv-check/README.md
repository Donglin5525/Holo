# AIContextSection 迁移等价性验收工具（P0-A）

方案：`docs/plans/2026-08-15-intent-routing-long-term-architecture.md` §4 P0。
验收要求：三块（纪念日/数据覆盖度/最近关联任务）从手写 builder 迁入注册表后，上下文渲染**逐字节等价**。

## 跑法

```bash
cd docs/holoai-audit/context-section-equiv-check
cp "../../../Holo/Holo APP/Holo/Holo/Services/AI/AIContextSection.swift" .
swiftc AIContextSection.swift equiv-main.swift -o ctx_equiv && ./ctx_equiv
```

工具会：stub 掉 UserContext 相关类型 → `AIContextSection.swift` **原样**参与编译 → 与 `equiv-main.swift` 内复刻的旧手写渲染（git HEAD 版本逐行照搬）在 14 组边界样例上逐字节比对（含：空数据、多条、覆盖度 rich/partial/empty、缺失来源 prefix(3) 截断、备忘单 0/3/15/16 条、「等共 N 项」后缀触发、全满组合）。

## 2026-08-15 首次验收结果

```
✅ 全部 14 组样例逐字节等价
```

后续任何 section 改动（格式调整/新增 section）跑此工具防回归；若有意改变输出格式，先更新本工具的 legacy 基准并注明动机。
