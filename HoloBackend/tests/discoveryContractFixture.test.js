// 双端契约对拍（2026-11-01 独立诊断报告问题1）：夹具 tests/fixtures/discovery-contract-candidates.json
// 是唯一真源——iOS DiscoveryContractTests 读同一文件做 Swift 严格解码对拍。
// 规则：server 判定为 validateDiscoveryOutput 最终结果（含修复层）；server=pass 时
// 交付形状客户端必须可消费（iOS 侧对同形状必须同判 pass）。此测试防「后端 200、
// 客户端 schema_invalid 锁当天」的契约缝隙复发。
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { validateDiscoveryOutput } from "../src/discovery/discoveryOutputSchema.js";

const fixture = JSON.parse(readFileSync(new URL("./fixtures/discovery-contract-candidates.json", import.meta.url), "utf8"));

for (const item of fixture.cases) {
  test(`契约夹具·${item.name}`, () => {
    let delivered = null;
    let threw = false;
    try {
      delivered = validateDiscoveryOutput(JSON.stringify(item.envelope), {
        expectedKind: "candidates",
        expectedRunID: item.envelope.runID,
        // 1.1.5 S1：夹具可声明请求 anchorNow 的时区偏移（修复层补全纯日期用）；未声明=不修
        timezoneOffset: item.timezoneOffset ?? null,
      });
    } catch {
      threw = true;
    }
    const serverPass = !threw && !!delivered?.envelope;
    if (item.server === "pass") {
      assert.equal(serverPass, true, `服务端应通过(含修复层)，实际拒绝`);
      // 交付形状随夹具存档（iOS DiscoveryContractTests 读 deliveredEnvelope 做严格解码对拍）：
      // 存档必须与服务端当前实际交付逐字段一致，否则 iOS 对拍的是过期形状
      assert.ok(item.deliveredEnvelope, "server=pass 用例必须存档 deliveredEnvelope");
      assert.deepEqual(delivered.envelope, item.deliveredEnvelope, "存档交付形状与服务端实际交付不一致");
    } else {
      assert.equal(serverPass, false, `服务端应拒绝，实际通过`);
    }
  });
}
