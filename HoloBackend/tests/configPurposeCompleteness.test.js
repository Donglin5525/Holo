// Config Purpose Completeness —— LLM purpose 配置完整性守门
//（2026-11-16 随机器守门体系设立）
//
// 病（4 次实锤：萃取/知识树/insight/vision）：新增 LLM purpose 忘配
// reasoningEffort → 空响应/超时，且只在真流量上暴露。
// 本测试断言：config 导出的每个 LLM purpose 配置都必须显式带
// reasoningEffort 字段。新增 purpose 忘配 → 测试红，发版前拦截。
//
// 运行：npm test（node --test tests/*.test.js）

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { loadConfig } = require('../src/config.js')

// 从 loadConfig() 结果里收集所有带 model 的 purpose 配置对象。
// config 结构若变化，这里同步调整（形态漂移本身也是信号）。
function collectLlmPurposes(node, path, out) {
  if (!node || typeof node !== 'object') return
  if (node.model && typeof node.model === 'string') {
    out.push({ path, cfg: node })
    return
  }
  for (const [k, v] of Object.entries(node)) {
    if (v && typeof v === 'object') collectLlmPurposes(v, path ? `${path}.${k}` : k, out)
  }
}

test('所有对话类 LLM purpose 配置必须显式带 reasoningEffort（4 次忘配实锤的机器守门）', () => {
  const config = loadConfig()
  const purposes = []
  collectLlmPurposes(config, '', purposes)
  assert.ok(purposes.length >= 10, `purpose 收集数量异常（${purposes.length} < 10），疑似 config 结构漂移，守门需更新`)
  // 豁免：embedding / asr 类端点不消费推理参数（历史坑针对 chat/completions 类调用）
  const exempt = p => /embedding|asr/i.test(p.path)
  const missing = purposes.filter(p => !exempt(p) && (!('reasoningEffort' in p.cfg) || p.cfg.reasoningEffort == null))
  assert.deepStrictEqual(
    missing.map(p => p.path),
    [],
    `以下 purpose 缺 reasoningEffort（历史坑：空响应/超时只在真流量暴露）：${missing.map(p => p.path).join(', ')}`
  )
})
