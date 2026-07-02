export function createMockChatProvider() {
  return {
    async complete(request) {
      if (request.purpose === "intent") {
        return mockIntentCompletion(request);
      }
      if (request.purpose === "finance_action_parser") {
        return mockFinanceActionParserCompletion(request);
      }
      if (request.purpose === "task_action_parser") {
        return mockTaskActionParserCompletion(request);
      }
      if (request.purpose === "agent_loop") {
        return mockAgentLoopCompletion(request);
      }

      return {
        id: "mock-chat-completion",
        provider: "mock",
        model: request.model,
        choices: [
          {
            index: 0,
            message: {
              role: "assistant",
              content: `Mock response for: ${lastUserMessage(request.messages)}`,
            },
            finish_reason: "stop",
          },
        ],
      };
    },

    async *stream(request) {
      const text = `Mock response for: ${lastUserMessage(request.messages)}`;
      const parts = text.split(" ");
      for (const part of parts) {
        yield {
          id: "mock-chat-completion",
          provider: "mock",
          model: request.model,
          choices: [
            {
              index: 0,
              delta: {
                content: part,
              },
              finish_reason: null,
            },
          ],
        };
      }
    },
  };
}

function lastUserMessage(messages) {
  const message = messages.findLast((item) => item.role === "user");
  return message?.content ?? "";
}

function mockIntentCompletion(request) {
  const input = lastUserMessage(request.messages);
  const content = JSON.stringify(classifyIntent(input));

  return {
    id: "mock-chat-completion",
    provider: "mock",
    model: request.model,
    choices: [
      {
        index: 0,
        message: {
          role: "assistant",
          content,
        },
        finish_reason: "stop",
      },
    ],
  };
}

function mockFinanceActionParserCompletion(request) {
  const input = lastUserMessage(request.messages);
  const periodsMatch = input.match(/分\s*(\d+)\s*期/);
  const amountMatch = input.match(/(\d+)/);
  const feeMatch = input.match(/(\d+)\s*手续费/);

  const content = JSON.stringify({
    amount: amountMatch ? amountMatch[1] : "0",
    type: "expense",
    note: "测试分期",
    transactionDate: "2026-06-03",
    categoryCandidate: "",
    installmentEnabled: "true",
    installmentTotalAmount: amountMatch ? amountMatch[1] : "0",
    installmentPeriods: periodsMatch ? periodsMatch[1] : "3",
    installmentFeePerPeriod: feeMatch ? feeMatch[1] : "0",
    installmentFirstDueDate: "2026-06-03",
  });

  return {
    id: "mock-finance-action-parser",
    provider: "mock",
    model: request.model,
    choices: [{ index: 0, message: { role: "assistant", content }, finish_reason: "stop" }],
  };
}

function mockTaskActionParserCompletion(request) {
  const input = lastUserMessage(request.messages);
  const dailyMatch = input.match(/每隔\s*(\d+)\s*天/);
  const weeklyMatch = input.match(/每周([一二三四五六日天])/);

  let result;
  if (dailyMatch) {
    result = {
      title: input.replace(/每隔\s*\d+\s*天/, "").trim() || "提醒",
      dueDate: "2026-06-03T20:00:00+08:00",
      repeatEnabled: "true",
      repeatType: "daily",
      repeatInterval: dailyMatch[1],
      repeatWeekdays: "",
      repeatMonthDay: "",
      repeatSummary: `每隔 ${dailyMatch[1]} 天`,
    };
  } else if (weeklyMatch) {
    const weekdayMap = { "日": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7, "天": 1 };
    const day = weekdayMap[weeklyMatch[1]] ?? 4;
    result = {
      title: input.replace(/每周[一二三四五六日天]/, "").trim() || "提醒",
      dueDate: "2026-06-03T20:00:00+08:00",
      repeatEnabled: "true",
      repeatType: "custom",
      repeatInterval: "1",
      repeatWeekdays: String(day),
      repeatMonthDay: "",
      repeatSummary: `每周${weeklyMatch[1]}`,
    };
  } else {
    result = {
      title: input.trim(),
      dueDate: "2026-06-03T20:00:00+08:00",
      repeatEnabled: "true",
      repeatType: "daily",
      repeatInterval: "1",
      repeatWeekdays: "",
      repeatMonthDay: "",
      repeatSummary: "每天",
    };
  }

  const content = JSON.stringify(result);
  return {
    id: "mock-task-action-parser",
    provider: "mock",
    model: request.model,
    choices: [{ index: 0, message: { role: "assistant", content }, finish_reason: "stop" }],
  };
}

function mockAgentLoopCompletion(request) {
  const content = JSON.stringify({
    status: "final_claims",
    reasoning: "mock agent loop 完成",
    toolRequests: [],
    claims: [
      {
        id: "c1",
        type: "observation",
        displayText: "mock claim",
        metricAssertions: [],
        evidenceIDs: [],
        prohibitedInferences: [],
        confidence: 0.5,
      },
    ],
    warnings: [],
  });

  return {
    id: "mock-agent-loop",
    provider: "mock",
    model: request.model,
    choices: [
      { index: 0, message: { role: "assistant", content }, finish_reason: "stop" },
    ],
  };
}

function classifyIntent(input) {
  const lowercased = input.toLowerCase();

  // ── Query patterns (highest priority) ──

  const hasSpendingAmountQuestion =
    /花了多少|多少钱|共花|总共|一共/.test(lowercased);
  const hasDirectFinanceTotalQuestion =
    /收入.*多少|收入是多少|支出.*多少|支出是多少|花了多少钱|消费.*多少/.test(lowercased);
  const hasCategoryConstraint =
    /买烟花|烟花|咖啡|打车|外卖|奶茶|香烟|买烟/.test(lowercased);
  const hasLatestQuery =
    /最近一次|上一次|哪一笔|距今多久|多久没/.test(lowercased);
  const hasHealthAnalysisQuestion =
    /睡眠|步数|健康|活动|状态不好|身体状态/.test(lowercased)
    && /怎么样|咋样|分析|趋势|看看|状态|不好/.test(lowercased);

  // 0. 健康状态 / 睡眠 / 步数趋势 → query_analysis
  if (hasHealthAnalysisQuestion) {
    return {
      mode: "query",
      items: [
        {
          id: "1",
          intent: "query_analysis",
          confidence: 0.9,
          extractedData: {
            analysisDomain: "health",
            ...(lowercased.includes("睡眠") ? { subDomain: "sleep" } : {}),
            periodLabel: lowercased.includes("最近") ? "最近" : "",
          },
        },
      ],
      needsClarification: false,
      clarificationQuestion: null,
    };
  }

  // 1. 品类关键词 + 消费金额提问 → flexible_data_query
  if (hasSpendingAmountQuestion && hasCategoryConstraint) {
    return {
      mode: "query",
      items: [
        {
          id: "1",
          intent: "flexible_data_query",
          confidence: 0.95,
          extractedData: {
            queryDomain: "finance",
            queryGoal: `统计${input}对应的消费金额`,
            rawConstraints: input.includes("今年")
              ? `今年, 关键词包含${extractKeyword(input)}`
              : `关键词包含${extractKeyword(input)}`,
          },
        },
      ],
      needsClarification: false,
      clarificationQuestion: null,
    };
  }

  // 2. 直接财务总额 → flexible_data_query
  if (hasDirectFinanceTotalQuestion) {
    return {
      mode: "query",
      items: [
        {
          id: "1",
          intent: "flexible_data_query",
          confidence: 0.95,
          extractedData: {
            queryDomain: "finance",
            queryGoal: `查询${input}对应的确定金额`,
            rawConstraints: buildDirectFinanceConstraints(input),
          },
        },
      ],
      needsClarification: false,
      clarificationQuestion: null,
    };
  }

  // 3. 最近一次/上一次 → flexible_data_query
  if (hasLatestQuery) {
    return {
      mode: "query",
      items: [
        {
          id: "1",
          intent: "flexible_data_query",
          confidence: 0.95,
          extractedData: {
            queryDomain: "finance",
            queryGoal: input,
            rawConstraints: buildDirectFinanceConstraints(input),
          },
        },
      ],
      needsClarification: false,
      clarificationQuestion: null,
    };
  }

  // 4. 其他确定金额提问 → flexible_data_query（不再走 query_analysis）
  if (hasSpendingAmountQuestion) {
    return {
      mode: "query",
      items: [
        {
          id: "1",
          intent: "flexible_data_query",
          confidence: 0.9,
          extractedData: {
            queryDomain: "finance",
            queryGoal: input,
            rawConstraints: input,
          },
        },
      ],
      needsClarification: false,
      clarificationQuestion: null,
    };
  }

  // 5. 分析/复盘/趋势/结构 → query_analysis
  if (/消费统计|支出统计|分析|复盘|趋势|结构|占比|总结/.test(lowercased)) {
    return {
      mode: "query",
      items: [
        {
          id: "1",
          intent: "query_analysis",
          confidence: 0.9,
          extractedData: {
            analysisDomain: "finance",
          },
        },
      ],
      needsClarification: false,
      clarificationQuestion: null,
    };
  }

  // 6. 能力查询 → query
  if (/你能做|帮我.*做|做什么|什么功能|你能帮我/.test(lowercased)) {
    return {
      mode: "query",
      items: [
        {
          id: "1",
          intent: "query",
          confidence: 0.9,
          extractedData: {},
        },
      ],
      needsClarification: false,
      clarificationQuestion: null,
    };
  }

  // ── Action patterns ──

  // 7. 习惯打卡
  if (/打卡|签到/.test(lowercased)) {
    return {
      mode: "single_action",
      items: [
        {
          id: "1",
          intent: "check_in",
          confidence: 0.95,
          extractedData: {
            habitName: input.replace(/今天|打卡|签到/g, "").trim() || "习惯",
          },
        },
      ],
      needsClarification: false,
      clarificationQuestion: null,
    };
  }

  // 8. 创建任务（含购物清单 subtasks）
  if (/提醒|待办|创建任务|去.*买/.test(lowercased)) {
    const extractedData = {};

    // 提取购物清单子任务
    const buyMatch = input.match(/买(.+)$/);
    if (buyMatch) {
      const rawItems = buyMatch[1]
        .split(/[、，,和]+/)
        .map((s) => s.trim())
        .filter(Boolean);
      if (rawItems.length >= 2) {
        extractedData.subtasks = rawItems
          .map((item) => (item.startsWith("买") ? item : `买${item}`))
          .join(",");
        const locationMatch = input.match(/去(.+?)买/);
        extractedData.title = locationMatch
          ? `${locationMatch[1]}购物`
          : "购物清单";
      } else {
        extractedData.title = input
          .replace(/^(明天|今天)(早上|上午|下午|晚上|傍晚)?/, "")
          .replace(/^(帮我|提醒我|要)/, "")
          .trim();
      }
    } else {
      extractedData.title = input
        .replace(/^(明天|今天)(早上|上午|下午|晚上|傍晚)?/, "")
        .replace(/^(帮我|提醒我|要)/, "")
        .trim();
    }

    // 提取日期和提醒时间
    if (/明天/.test(input)) {
      if (/早上|上午/.test(input)) {
        extractedData.dueDate = "2026-06-08 09:00";
        extractedData.reminderDate = "2026-06-08 09:00";
      } else if (/下午/.test(input)) {
        extractedData.dueDate = "2026-06-08 15:00";
        extractedData.reminderDate = "2026-06-08 15:00";
      } else {
        extractedData.dueDate = "2026-06-08";
      }
    }

    return {
      mode: "single_action",
      items: [
        {
          id: "1",
          intent: "create_task",
          confidence: 0.95,
          extractedData,
        },
      ],
      needsClarification: false,
      clarificationQuestion: null,
    };
  }

  // 9. 记录收入
  if (/发工资|工资\s*\d|收钱/.test(input) || /工资/.test(lowercased)) {
    const amountMatch = input.match(/(\d+)/);
    return {
      mode: "single_action",
      items: [
        {
          id: "1",
          intent: "record_income",
          confidence: 0.95,
          extractedData: {
            amount: amountMatch ? amountMatch[1] : "",
            categoryCandidate: "工资",
            ...extractTransactionDate(input),
          },
        },
      ],
      needsClarification: false,
      clarificationQuestion: null,
    };
  }

  // 10. 记录支出
  {
    const amountMatch = input.match(/(\d+)/);
    if (amountMatch) {
      return {
        mode: "single_action",
        items: [
          {
            id: "1",
            intent: "record_expense",
            confidence: 0.95,
            extractedData: {
              amount: amountMatch[1],
              categoryCandidate: extractCategoryCandidate(input),
              ...extractTransactionDate(input),
            },
          },
        ],
        needsClarification: false,
        clarificationQuestion: null,
      };
    }
  }

  // unknown 兜底
  return {
    mode: "unknown",
    items: [
      {
        id: "1",
        intent: "unknown",
        confidence: 0.4,
        extractedData: {},
      },
    ],
    needsClarification: true,
    clarificationQuestion: "我没完全理解这句话，你可以换个方式说吗？",
  };
}

function extractCategoryCandidate(input) {
  const candidates = [
    "午饭", "晚餐", "早餐", "夜宵", "咖啡",
    "打车", "外卖", "买烟", "手办", "肯德基",
  ];
  for (const c of candidates) {
    if (input.includes(c)) return c;
  }
  return "";
}

function extractTransactionDate(input) {
  if (input.includes("昨天") || input.includes("昨日")) {
    return { transactionDate: "2026-06-02" };
  }
  if (input.includes("今天") || input.includes("今日")) {
    return { transactionDate: "2026-06-03" };
  }
  return {};
}

function extractKeyword(input) {
  for (const keyword of ["烟花", "咖啡", "打车", "外卖", "奶茶", "香烟", "买烟"]) {
    if (input.includes(keyword)) return keyword;
  }
  return input;
}

function buildDirectFinanceConstraints(input) {
  const parts = [];
  if (input.includes("今年")) parts.push("今年");
  if (input.includes("本月") || input.includes("这个月")) parts.push("本月");
  if (input.includes("收入")) parts.push("收入");
  if (input.includes("支出") || input.includes("消费") || input.includes("花")) parts.push("支出");
  return parts.length > 0 ? parts.join(", ") : input;
}
