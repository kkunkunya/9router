import { describe, expect, it } from "vitest";
import { openaiResponsesToOpenAIResponse } from "../../open-sse/translator/response/openai-responses.js";
import { initState } from "../../open-sse/translator/index.js";
import { FORMATS } from "../../open-sse/translator/formats.js";

describe("Responses image_generation_call → OpenAI Chat", () => {
  const jpegB64 = "/9j/4AAQSkZJRgABAQAAAQABAAD"; // JPEG magic header

  function streamEvents(events) {
    const state = initState(FORMATS.OPENAI_RESPONSES);
    const chunks = [];
    for (const evt of events) {
      const out = openaiResponsesToOpenAIResponse(evt, state);
      if (out) chunks.push(out);
    }
    // flush
    const fin = openaiResponsesToOpenAIResponse(null, state);
    if (fin) chunks.push(fin);
    return chunks;
  }

  it("surfaces completed image_generation_call result as markdown image", () => {
    const chunks = streamEvents([
      { type: "response.output_item.added", data: { item: { id: "ig_1", type: "image_generation_call", status: "in_progress", result: null } } },
      { type: "response.output_item.done", data: { item: { id: "ig_1", type: "image_generation_call", status: "completed", result: jpegB64, prompt: "a red circle" } } },
      { type: "response.completed", data: { response: { usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 } } } },
    ]);

    const content = chunks.map((c) => c.choices?.[0]?.delta?.content || "").join("");
    expect(content).toBe(`![image](data:image/jpeg;base64,${jpegB64})`);
  });

  it("passes through data URI results unchanged", () => {
    const uri = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUg==";
    const chunks = streamEvents([
      { type: "response.output_item.done", data: { item: { type: "image_generation_call", status: "completed", result: uri } } },
      { type: "response.completed", data: { response: { usage: {} } } },
    ]);
    const content = chunks.map((c) => c.choices?.[0]?.delta?.content || "").join("");
    expect(content).toBe(`![image](${uri})`);
  });

  it("ignores in-progress or empty image results", () => {
    const chunks = streamEvents([
      { type: "response.output_item.done", data: { item: { type: "image_generation_call", status: "failed", result: null } } },
      { type: "response.completed", data: { response: { usage: {} } } },
    ]);
    const content = chunks.map((c) => c.choices?.[0]?.delta?.content || "").join("");
    expect(content).toBe("");
  });
});
