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

// 个人情境规划（contextual_planning）确定性分流：只认语义结构组合，不维护
// 「日本、旅行」等目的地/领域词表（实施方案 §5.4）。命中需同时满足：
//   ① 用户表达一个未来事件/目标/决策（FUTURE_EVENT_PATTERN）；
//   ② 请求准备、规划、安排、注意事项、清单、避免遗漏或拆解（PLANNING_REQUEST_PATTERN）；
//   ③ 不是明确单项写操作（EXECUTION_PATTERN 全局拦 + PLANNING_BLOCK_PATTERN 二次拦）。
// 其余输入不进规划分支，继续交给 LLM Router。
const PLANNING_REQUEST_PATTERN = /准备|筹备|规划|安排|清单|注意事项|要带什么|需要做什么|要做些什么|列一下|列一列|列下|梳理|拆解|别遗漏|不要遗漏|怕遗漏|准备什么|准备哪些/;
const FUTURE_EVENT_PATTERN = /要去|打算去|计划去|准备去|要开始|打算开始|计划开始|要[出搬回开考参办]|要提前|打算|计划|即将|就要|快要|下[周月天年]|下个月|下礼拜|后天|明天|过[几两三四五]天|月底|年底|国庆|春节|五一|十一|周[一二三四五六日末]前|[0-9一二三四五六七八九十]+\s*月\s*[0-9一二三四五六七八九十]+\s*[日号]?|出发前|出发之前|行前|考前|术前|上线前|搬迁前|搬家前|回家前|出门前|开始前/;
// 「创建/新建/添加……任务|待办|提醒|日程」是单项写操作，即使句中带准备类词也不进规划。
const PLANNING_BLOCK_PATTERN = /(?:创建|新建|添加|建个|建一个|加个)[^，。]{0,15}(?:任务|待办|提醒|日程)/;

/**
 * 对“基于 Holo 个人数据总结近期状态”这类高置信查询做确定性分流。
 * 这里只覆盖语义边界明确的窄集合；其余输入继续交给 LLM Router。
 */
export function resolveDeterministicIntent(input) {
  const text = String(input ?? "").trim().toLowerCase();
  if (!text) return null;

  const hasSelfReference = SELF_PATTERN.test(text);
  if (EXECUTION_PATTERN.test(text)) return null;

  // 规划分支：放在 OWN_EXTERNAL/第三方排除之前——「我的项目上线前」「孩子考前」
  // 这类以用户为执行主体的家庭/工作准备是正例；单项写操作已被上面拦掉。
  if (
    PLANNING_REQUEST_PATTERN.test(text) &&
    FUTURE_EVENT_PATTERN.test(text) &&
    !PLANNING_BLOCK_PATTERN.test(text)
  ) {
    return {
      mode: "query",
      items: [
        {
          id: "1",
          intent: "contextual_planning",
          confidence: 0.99,
          routeSource: "deterministic",
          routeReasonCode: "EVENT_PREPARATION_PLAN",
          extractedData: {},
        },
      ],
      needsClarification: false,
      clarificationQuestion: null,
    };
  }

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
        routeSource: "deterministic",
        routeReasonCode: "SELF_RECENT_STATUS_QUERY",
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
