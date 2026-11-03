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
      });
    } catch {
      threw = true;
    }
    const serverPass = !threw && !!delivered?.envelope;
    if (item.server === "pass") {
      assert.equal(serverPass, true, `服务端应通过(含修复层)，实际拒绝`);
      // 交付形状随夹具存档，供 iOS 对拍与人工核对
      item.deliveredEnvelope = delivered.envelope;
    } else {
      assert.equal(serverPass, false, `服务端应拒绝，实际通过`);
    }
  });
}
