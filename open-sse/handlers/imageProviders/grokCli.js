// Grok Build (cli-chat-proxy.grok.com) image generation via Responses API + SSE.
// Mirrors codex.js: the image arrives as an `image_generation_call` item whose
// `result` field carries the base64 payload — Grok emits JPEG.
import { randomUUID } from "node:crypto";
import { nowSec } from "./_base.js";
import {
  GROK_CLI_BASE_URL,
  GROK_CLI_CLIENT_IDENTIFIER,
  GROK_CLI_MODEL,
  GROK_CLI_USER_AGENT,
  GROK_CLI_VERSION,
} from "../../config/grokCli.js";

const GROK_RESPONSES_URL = `${GROK_CLI_BASE_URL}/responses`;

// Parse Grok SSE stream → final base64 image.
async function parseStream(response, log) {
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let imageB64 = null;
  let lastEvent = null;

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });

    let sepIdx;
    while ((sepIdx = buffer.indexOf("\n\n")) !== -1) {
      const block = buffer.slice(0, sepIdx);
      buffer = buffer.slice(sepIdx + 2);

      const lines = block.split("\n");
      let eventName = null;
      let dataStr = "";
      for (const line of lines) {
        if (line.startsWith("event:")) eventName = line.slice(6).trim();
        else if (line.startsWith("data:")) dataStr += line.slice(5).trim();
      }
      if (!eventName) continue;
      if (eventName !== lastEvent) {
        log?.info?.("IMAGE", `grok progress: ${eventName}`);
        lastEvent = eventName;
      }

      if (eventName === "response.output_item.done" && dataStr) {
        try {
          const data = JSON.parse(dataStr);
          const item = data?.item;
          if (item?.type === "image_generation_call" && item.result) {
            imageB64 = item.result;
          }
        } catch {}
      }
    }
  }
  return imageB64;
}

// SSE Response piping generation progress + done event (mirrors codex).
function buildSseResponse(providerResponse, log, onSuccess) {
  const stream = new ReadableStream({
    async start(controller) {
      const enc = new TextEncoder();
      const send = (event, data) => {
        controller.enqueue(enc.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`));
      };
      try {
        const b64 = await parseStream(providerResponse, log);
        if (!b64) {
          send("error", { message: "Grok did not return an image. Subscription or image quota required." });
        } else {
          if (onSuccess) await onSuccess();
          send("done", { created: nowSec(), data: [{ b64_json: b64 }] });
        }
      } catch (err) {
        send("error", { message: err?.message || "Stream failed" });
      } finally {
        controller.close();
      }
    },
  });
  return new Response(stream, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache, no-transform",
      "Connection": "keep-alive",
      "X-Accel-Buffering": "no",
      "Access-Control-Allow-Origin": "*",
    },
  });
}

export default {
  stream: true,
  buildUrl: () => GROK_RESPONSES_URL,
  buildHeaders: (creds) => {
    const psd = creds?.providerSpecificData || {};
    const sessionId = randomUUID();
    const headers = {
      "accept": "text/event-stream, application/json",
      "authorization": `Bearer ${creds?.accessToken || ""}`,
      "content-type": "application/json",
      "user-agent": GROK_CLI_USER_AGENT,
      "x-xai-token-auth": "xai-grok-cli",
      "x-grok-client-identifier": GROK_CLI_CLIENT_IDENTIFIER,
      "x-grok-client-version": GROK_CLI_VERSION,
      "x-grok-session-id": sessionId,
      "x-grok-conv-id": sessionId,
      "x-grok-req-id": randomUUID(),
      "x-grok-turn-idx": "1",
      "x-grok-model-override": GROK_CLI_MODEL,
    };
    if (psd.email) headers["x-email"] = psd.email;
    if (psd.userId) headers["x-userid"] = psd.userId;
    return headers;
  },
  buildBody: (model, body) => {
    const imgTool = { type: "image_generation" };
    if (body.size && body.size !== "") imgTool.size = body.size;
    if (body.quality && body.quality !== "") imgTool.quality = body.quality;
    return {
      model: GROK_CLI_MODEL,
      instructions: "",
      input: [{ type: "message", role: "user", content: [{ type: "input_text", text: body.prompt }] }],
      tools: [imgTool],
      tool_choice: "auto",
      parallel_tool_calls: false,
      stream: true,
      store: false,
      reasoning: null,
    };
  },
  async parseResponse(response, { log, streamToClient, onRequestSuccess }) {
    if (streamToClient) {
      return { sseResponse: buildSseResponse(response, log, onRequestSuccess) };
    }
    const b64 = await parseStream(response, log);
    if (!b64) {
      throw new Error("Grok did not return an image. Subscription or image quota required.");
    }
    return { created: nowSec(), data: [{ b64_json: b64 }] };
  },
  normalize: (responseBody) => responseBody,
};
