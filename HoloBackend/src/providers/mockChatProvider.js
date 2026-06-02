export function createMockChatProvider() {
  return {
    async complete(request) {
      if (request.purpose === "intent") {
        return mockIntentCompletion(request);
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

function classifyIntent(input) {
  const lowercased = input.toLowerCase();
  const hasSpendingAmountQuestion =
    /花了多少|多少钱|共花|总共|一共/.test(lowercased);
  const hasDirectFinanceTotalQuestion =
    /收入.*多少|收入是多少|支出.*多少|支出是多少|花了多少钱|消费.*多少/.test(lowercased);
  const hasCategoryConstraint =
    /买烟花|烟花|咖啡|打车|外卖|奶茶|香烟|买烟/.test(lowercased);

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

  if (hasSpendingAmountQuestion || /消费统计|支出统计|分析|复盘/.test(lowercased)) {
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
