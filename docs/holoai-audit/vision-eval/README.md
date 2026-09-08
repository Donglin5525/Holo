# 截图识别记账 · 视觉抽取评测（M0）

> 方案：`docs/plans/2026-09-09-screenshot-receipt-billing-plan.md` §7。目的：在写任何代码之前，用同一套样张对候选视觉模型同集对跑，选出 vision_extraction 的模型并拿到字段准确率与单次成本实测。

## 目录结构

- `tools/render_corpus.swift` — 合成样张生成器（AppKit 渲染，无第三方依赖）：`swift tools/render_corpus.swift corpus`
- `corpus/` — 24 张样张 + `manifest.json`（期望结果）
- `scripts/eval-vision-extraction.mjs`（仓库根 `scripts/`）— 评测脚本，读 `HoloBackend/.env` 里的供应商 key，不动代码
- `results/` — 跑分结果 JSON（按模型分文件）

## 样张构成（24 张）

| 类别 | 数量 | 覆盖 |
|---|---|---|
| 小票/发票（可记账） | 11 | 餐饮/商超/便利店/火锅/出行/加油站/药店/现金支付/电子发票（含一张退款应判收入） |
| 支付类截图（可记账） | 3 | 京东/美团/猫眼订单详情，已完成支付 |
| 多笔 | 1 | 支付宝账单截图含两笔消费 |
| 模糊（宽口径） | 1 | 低对比小票，抽出正确或诚实拒识都算过 |
| 资金流转（必须拦截） | 2 | 微信转账、信用卡还款——误记会虚增支出，是本功能最重要的安全指标 |
| 其他拒识 | 6 | 余额宝理财页/聊天记录/纯测试图/购物清单（二期口径）/待付款订单/支付失败 |
| 外币 | 1 | 美元小票（拍板 7：一期不支持） |

## 图片理解单契约（vision_extraction 输出，与后端 prompt 同源）

```json
{
  "imageType": "receipt | payment_screenshot | transfer_screenshot | wealth_screenshot | list_note | foreign_currency | pending_order | unrelated",
  "confidence": 0.0,
  "summary": "一句话中文摘要",
  "merchant": "商户名或 null",
  "paidAt": "YYYY-MM-DD 或 null",
  "paymentChannel": "微信支付 | 支付宝 | 现金 | 银行卡尾号后4位 | null",
  "currency": "CNY",
  "items": [{ "name": "条目", "amount": 0 }],
  "transactions": [{ "type": "expense | income", "amount": 0, "note": "摘要", "date": "YYYY-MM-DD" }],
  "rejectReason": "不可记账图型时给一句中文原因，否则 null"
}
```

判定规则（与产品拍板一致）：transactions 只收「已完成支付」的交易；转账/还款/理财/清单/外币/未支付/支付失败/无关 → 空数组 + rejectReason；退款 = income；一张图多笔 = 多笔 transactions；不确定 → confidence < 0.6，不许编造。

## 指标

- **拦截召回**：转账/还款/理财/待付款必须拒识（x01/x02/x06/x07）——安全红线
- **误拒率**：可记账样张被拒识的比例
- 图型准确率 / 金额准确率（集合匹配，容差 0.005）/ 日期 / 商户 / 支付通道
- 收支方向（退款=income）
- usage tokens 累计（折算单次成本）

## 选型结论（2026-09-09，五轮评测）

**选定：qwen3-vl-plus（DashScope 兼容模式，temperature=0）。** 普惠档 qwen3-vl-flash 落选。

| 轮次 | 语料 | qwen3-vl-plus | qwen3-vl-flash | 当轮修复 |
|---|---|---|---|---|
| 1 | PNG 初版 prompt | 22/24 | 22/24 | — |
| 2 | +货币红线/聊天图型规则 | 23/24 | 21/24 | 聊天截图图型已修 |
| 3 | +amountOriginalText+确定性护栏+图型口径放宽 | 23/24 | 22/24 | 订单截图口径放宽 |
| 4 | +外币拒识少样本示例+退款方向规则 | **24/24** | 22/24 | 外币拒识修复 |
| 5（JPEG 复测） | 语料转 JPEG 0.9 | 23/24 | — | 稳定性观察轮 |

关键事实（写进后续设计的）：
- **普惠档 flash 两次栽在安全项**（外币拒识、退款方向），且跨轮次不稳定——省的钱不值得。
- **模型会伪造「逐字抄录」**：美元小票被它抄成「¥14.47」+ currency:"CNY"。单靠 prompt 规则拦不住货币归一化，最终靠「外币少样本示例」治住；**下游确定性护栏（amountOriginalText 含外币符号→强制拒识）必须保留**，对齐 BillImportAIService「AI 只指认不发明」铁律。
- 资金流转拦截（转账/还款/理财/待付款）**五轮全轮次 4/4 零失手**——安全红线比字段抽取稳。
- 单张样张跨轮偶发抖动（某轮一张误拒/误判，下轮自愈）：产品侧已有出口——拒识气泡给「重试/手填」，确认卡是最后一道人工闸门。
- 单均消耗 ~3240 tokens/张（图≈2500 + prompt≈700）；精度关键在少样本示例，不要为省 token 删它。
- glm-4v-plus 未测（本地 .env 无智谱 key，ZHIPU_API_KEY 为空占位）；不阻塞选型，如需对比补 key 后 `--models zhipu` 即跑。

## 运行

```bash
# 重新生成样张
cd docs/holoai-audit/vision-eval && swift tools/render_corpus.swift corpus

# 小批试跑（6 张）
node ../../scripts/eval-vision-extraction.mjs --limit 6

# 全量
node ../../scripts/eval-vision-extraction.mjs
```

模型与 key 从 `HoloBackend/.env` 读（QWEN_API_KEY/QWEN_BASE_URL、ZHIPU_API_KEY/ZHIPU_BASE_URL），可用 `--models qwen,zhipu`、`--model-qwen qwen-vl-max-latest`、`--model-zhipu glm-4v-plus` 覆盖。

## 局限与后续

- 合成样张只能验证「抽取与拦截能力」，**不能替代真实小票的鲁棒性验证**——M2 验收阶段东林真机拍的实图要回灌进本评测集。
- 干扰图暂无真实照片类（风景/自拍），后续用真实图片补。
