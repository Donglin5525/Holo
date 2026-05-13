export function createMockAsrProvider() {
  return {
    async transcribe() {
      return {
        text: "Mock transcript",
        provider: "mock",
        duration: null,
        confidence: null,
      };
    },
  };
}
