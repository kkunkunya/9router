import { describe, expect, it } from "vitest";
import { DefaultExecutor } from "../../open-sse/executors/default.js";

describe("OpenAI-compatible fast tier", () => {
  it("maps Codex fast to the upstream priority tier", () => {
    const body = new DefaultExecutor("openai-compatible-chat-test").transformRequest("gpt-5.6-sol", {
      model: "gpt-5.6-sol",
      messages: [{ role: "user", content: "hi" }],
      service_tier: "fast",
    });

    expect(body.service_tier).toBe("priority");
  });
});
