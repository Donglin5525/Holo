const DOMAIN_PATTERNS = [
  ["finance", /财务|消费|花销|支出|收入|预算|账单|账户|资产|负债/],
  ["health", /健康|睡眠|步数|运动|身体|恢复|活动|锻炼|心率|体重|心情/],
  ["habit", /习惯|打卡|坚持/],
  ["task", /任务|待办|完成情况/],
  ["goal", /目标|进度/],
  ["thought", /观点|想法|思考/],
];

const RECENT_PATTERN = /最近|近期|近来|这段时间|这一阵|这阵子|近况|现在|当前|今天|今日|这周|本周|这个月|本月/;
const STATE_PATTERN = /状态|情况|近况|表现|变化|趋势|过得|整体|综合/;
const QUESTION_PATTERN = /怎么样|如何|咋样|好吗|好不好|还好吗|看看|看下|分析|复盘|总结|评估|趋势|说说|告诉我|有什么变化|怎么办|[？?]/;
const SELF_PATTERN = /我(?!们)|自己/;
const ASSISTANT_OR_THIRD_PARTY_PATTERN = /你最近|你近期|你现在|他最近|她最近|他们最近|我们最近|咱们最近|家人最近|朋友最近|孩子最近|父母最近|同事最近|伴侣最近/;
const EXTERNAL_SUBJECT_PATTERN = /天气|股市|公司|项目|产品|订单|网络|服务器|接口|服务状态|系统状态|holo\s*(app|服务|系统)|app\s*状态|应用状态/i;
const OWN_EXTERNAL_SUBJECT_PATTERN = /(?:我的|我们(?:的)?)(?:公司|项目|产品|订单|网络|服务器|接口|app|应用)/i;
const EXECUTION_PATTERN = /记(?:一笔|账|下来)|帮我记录|请记录|记录(?:一笔|一下|心情|体重)|创建(?:任务|待办)|新建(?:任务|待办)|提醒我|打卡(?!情况|状态|记录|趋势)|签到(?!情况|状态|记录|趋势)|(?:完成|删除|修改|更新)(?:这个|该|我的)?任务/;

/**
 * 对“基于 Holo 个人数据总结近期状态”这类高置信查询做确定性分流。
 * 这里只覆盖语义边界明确的窄集合；其余输入继续交给 LLM Router。
 */
export function resolveDeterministicIntent(input) {
  const text = String(input ?? "").trim().toLowerCase();
  if (!text) return null;

  const hasSelfReference = SELF_PATTERN.test(text);
  if (EXECUTION_PATTERN.test(text)) return null;
  if (OWN_EXTERNAL_SUBJECT_PATTERN.test(text)) return null;
  if (!hasSelfReference && ASSISTANT_OR_THIRD_PARTY_PATTERN.test(text)) return null;
  if (!hasSelfReference && EXTERNAL_SUBJECT_PATTERN.test(text)) return null;

  const domains = DOMAIN_PATTERNS
    .filter(([, pattern]) => pattern.test(text))
    .map(([domain]) => domain);
  const hasRecentContext = RECENT_PATTERN.test(text);
  const hasStateSignal = STATE_PATTERN.test(text);
  const hasQuestionSignal = QUESTION_PATTERN.test(text);
  const selfStatusShorthand = hasSelfReference && /怎么样|如何|咋样|好吗|好不好|还好吗/.test(text);
  const domainStatusShorthand = domains.length > 0 && /怎么样|如何|咋样|状态|情况|趋势/.test(text);

  if (!hasRecentContext || !hasQuestionSignal) return null;
  if (!hasStateSignal && !selfStatusShorthand && !domainStatusShorthand) return null;

  const analysisDomain = domains.length === 1 ? domains[0] : "cross_domain";
  const extractedData = {
    analysisDomain,
    analysisScope: analysisDomain === "cross_domain" ? "holistic" : "domain",
    periodLabel: inferPeriodLabel(text),
  };
  if (analysisDomain === "health" && /睡眠/.test(text)) {
    extractedData.subDomain = "sleep";
  }

  return {
    mode: "query",
    items: [
      {
        id: "1",
        intent: "query_analysis",
        confidence: 0.99,
        extractedData,
      },
    ],
    needsClarification: false,
    clarificationQuestion: null,
  };
}

/**
 * 命中确定性规则时直接生成兼容 Chat Completions 的响应，绕过模型调用。
 */
export function buildDeterministicIntentCompletion(messages, model) {
  const input = [...(messages ?? [])]
    .reverse()
    .find((message) => message?.role === "user")
    ?.content;
  const intent = resolveDeterministicIntent(input);
  if (!intent) return null;

  return {
    id: "holo-deterministic-intent",
    provider: "holo-rules",
    model,
    choices: [
      {
        index: 0,
        message: {
          role: "assistant",
          content: JSON.stringify(intent),
        },
        finish_reason: "stop",
      },
    ],
  };
}

function inferPeriodLabel(text) {
  if (/今天|今日|现在|当前/.test(text)) return "今天";
  if (/这周|本周/.test(text)) return "本周";
  if (/这个月|本月/.test(text)) return "本月";
  return "最近";
}
