export function createMockChatProvider() {
  return {
    async complete(request) {
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
