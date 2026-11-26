#!/usr/bin/env bash
# 想法主题归类评测 · 本机起「线上同款」后端
#
# 用法（在 HoloBackend 目录下）：bash scripts/thought-topic-eval/serve.sh [端口，默认 8797]
#
# 做三件事：
#   1. 独立端口 + 评测专用 SQLite（不碰本地开发库，更不碰线上）；
#   2. 用线上归类路由的同款配置覆盖 .env（本机 .env 是 deepseek-chat，与线上不一致）；
#   3. 启动前打印实际生效的两条路由，留档核对。
# 线上值来源：2026-11-24 从运行中的容器只读取得模型名（未读任何密钥）。
set -euo pipefail

BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_DIR="$BACKEND_DIR/../docs/thoughts/plans/2026-11-24-想法主题归类准确性闭环/eval/private/run"
mkdir -p "$RUN_DIR"
cd "$BACKEND_DIR"

# 本机 .env 的 QWEN_API_KEY 若是空串，config.js 的「缺失才回退 DASHSCOPE_API_KEY」不会生效
# （空串不是 null）。这里显式回退到同一 DashScope 兼容通道的 DASHSCOPE_API_KEY；钥匙不落日志。
# 想用与线上同一把钥匙：在 HoloBackend/.env 填 QWEN_API_KEY 后重启本脚本即可。
if [ -z "${QWEN_API_KEY:-}" ]; then
  QWEN_API_KEY="$(node --input-type=module -e 'import "dotenv/config"; process.stdout.write(process.env.QWEN_API_KEY || process.env.DASHSCOPE_API_KEY || "")')"
  export QWEN_API_KEY
  echo "QWEN_API_KEY 为空：本次使用 .env 的 DASHSCOPE_API_KEY（同属 DashScope 兼容通道，模型与线上一致，计费走这把钥匙的账号）"
fi

export PORT="${1:-8797}"
export HOLO_DB_PATH="$RUN_DIR/backend-eval.db"
export HOLO_CHAT_PROVIDER="qwen"
export HOLO_CHAT_MODEL="qwen3.7-flash"
export HOLO_CHAT_REASONING_EFFORT="none"
export HOLO_EMBEDDING_PROVIDER="qwen"
export HOLO_EMBEDDING_MODEL="text-embedding-v3"
export HOLO_THOUGHT_SEMANTIC_PRIVACY_VERIFIED="true"
# 自动发现主题时给一簇笔记起名（/v1/thoughts/topic-name），线上同款开关
export HOLO_THOUGHT_TOPIC_INSIGHT_PRIVACY_VERIFIED="true"

# 费用护栏（backgroundCostGuard）：价目表取线上的值（qwen 牌价；代码默认还是 DeepSeek 时代的 3 / 9）。
# 上限只对这台本机评测后端放宽——默认的「单设备 ¥0.30/天、全局 ¥3/天」是给真实用户流量定的，
# 一场 600 条 × 3 轮的评测会把它撞穿，之后每个请求都在入口被挡（2026-11-25 实踩）。
export HOLO_BACKGROUND_INPUT_PRICE="0.2" HOLO_BACKGROUND_OUTPUT_PRICE="0.8" HOLO_BACKGROUND_CACHED_PRICE="0.04"
export HOLO_BACKGROUND_DAILY_CNY="5" HOLO_BACKGROUND_MONTHLY_CNY="100"
export HOLO_BACKGROUND_GLOBAL_DAILY_CNY="30" HOLO_BACKGROUND_GLOBAL_MONTHLY_CNY="300"

echo "评测用后端生效路由（应与线上一致）："
node --input-type=module -e '
import "dotenv/config";
import { loadConfig } from "./src/config.js";
const config = loadConfig();
for (const purpose of ["thought_semantic_relate_v1", "thought_embedding"]) {
  const route = config.routes[purpose];
  console.log(`  ${purpose}: ${route.provider} / ${route.model} / temperature=${route.temperature} / maxTokens=${route.maxTokens} / reasoningEffort=${route.reasoningEffort} / dimensions=${route.dimensions}`);
}
const guard = config.backgroundCost;
console.log(`  费用护栏（仅本机评测放宽）: 单设备 ${guard.dailyCNY} 元/天，全局 ${guard.globalDailyCNY} 元/天；单价 ${guard.inputPerMillionCNY} / ${guard.outputPerMillionCNY} 元每百万 tokens`);
'
exec node src/server.js
