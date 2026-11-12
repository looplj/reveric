import assert from "node:assert/strict";
import { test } from "node:test";
import type {
  ActionContext,
  ActionResult,
  PluginServices,
  PluginSetup,
  ToolContext,
  HttpRequest,
  JsonObject,
  ToolRegistration,
} from "reveric-plugin-sdk";
import { apply } from "../src/index";

const endpoint =
  "https://ai-gateway.edgeone.link/v1/providers/zhuque-text/classify";
const sample = {
  status: "success",
  softmax_confidence: 0.0019,
  ratio_confidence: 0,
  labels_ratio: { "0": 1, "1": 0, "2": 0 },
  segment_labels: [
    {
      text: "第二段",
      label: 1,
      conf: 0.82,
      order: 2,
      position: [6, 9],
    },
    {
      text: "hello world",
      label: 0,
      conf: 0.0019,
      order: 1,
      position: [0, 11],
    },
  ],
  usage: { total_tokens: 50 },
  msg: "",
  makers_models_usage: { total_tokens: 30 },
};
const detected = {
  ok: true,
  summary:
    "人工 100.0%，AI 0.0%，疑似 AI 0.0%。整体置信度 0.0019，疑似风险占比 0。",
  human_ratio: 1,
  ai_ratio: 0,
  suspected_ratio: 0,
  softmax_confidence: 0.0019,
  ratio_confidence: 0,
  segments: [
    {
      text: "hello world",
      label: "human",
      confidence: 0.0019,
      order: 1,
      start: 0,
      end: 11,
    },
    {
      text: "第二段",
      label: "ai",
      confidence: 0.82,
      order: 2,
      start: 6,
      end: 9,
    },
  ],
  usage: { characters: 50, makers_tokens: 30 },
};

function harness(
  body: unknown = sample,
  status = 200,
  key: string | null = "test-key",
  thrown?: Error,
) {
  const tools = new Map<string, ToolRegistration>();
  const actions = new Map<string, () => Promise<ActionResult>>();
  const requests: { url: string; init?: HttpRequest }[] = [];
  const logs: unknown[] = [];
  const unavailable = async (): Promise<never> => {
    throw new Error("Unexpected host API");
  };
  const plugin = { id: "reveric.zhuque", version: "1.0.0" };
  const services: PluginServices = {
    plugin,
    sqlite: {
      query: unavailable,
      execute: unavailable,
      transaction: unavailable,
    },
    ai: { listModels: unavailable, generateText: unavailable },
    http: {
      fetch: async (url, init) => {
        requests.push({ url, init });
        if (thrown) throw thrown;
        return {
          status,
          url,
          headers: {},
          body: typeof body === "string" ? body : JSON.stringify(body),
        };
      },
    },
    log: {
      info: (...args) => {
        logs.push(args);
      },
      warn: (...args) => {
        logs.push(args);
      },
      error: (...args) => {
        logs.push(args);
      },
    },
    secrets: {
      get: async (name) => {
        assert.equal(name, "apiKey");
        return key;
      },
    },
    settings: { get: unavailable },
    storage: { get: unavailable, set: unavailable, remove: unavailable },
  };
  const unexpected = () => {
    throw new Error("Unexpected registration");
  };
  const setup: PluginSetup = {
    plugin,
    tools: {
      register: (tool) => {
        tools.set(tool.name, tool);
      },
    },
    prompts: { context: unexpected, system: unexpected },
    tasks: { register: unexpected },
    pages: { registerAction: unexpected },
    settings: {
      registerAction: (name, handler) => {
        const context: ActionContext = { ...services, callId: "test" };
        actions.set(name, () => handler(context));
      },
    },
  };
  apply(setup);
  const context: ToolContext = {
    ...services,
    callId: "test",
    request: {
      requestId: "test",
      sessionId: "test",
      workId: null,
      agentId: "test",
      mode: "chat",
    },
    chapters: { list: unavailable, get: unavailable, update: unavailable },
    characters: { list: unavailable, get: unavailable, update: unavailable },
  };
  return {
    tools,
    actions,
    requests,
    logs,
    run: (input: JsonObject) =>
      tools.get("ZhuqueDetect")!.handler(input, context),
  };
}

test("registers the detector without reading credentials during apply", () => {
  const h = harness();
  assert.deepEqual([...h.tools.keys()], ["ZhuqueDetect"]);
  assert.deepEqual([...h.actions.keys()], ["verifyApiKey"]);
  assert.equal(h.tools.get("ZhuqueDetect")?.display?.resultPath, "summary");
  assert.equal(h.requests.length, 0);
});

test("detect maps official labels and sends merged text by default", async () => {
  const h = harness();
  assert.deepEqual(await h.run({ text: "hello world第二段" }), detected);
  assert.equal(h.requests[0].url, endpoint);
  assert.equal(h.requests[0].init?.method, "POST");
  assert.equal(h.requests[0].init?.timeoutMs, 45000);
  assert.equal(h.requests[0].init?.headers?.Authorization, "Bearer test-key");
  assert.equal(
    h.requests[0].init?.headers?.["Content-Type"],
    "application/json",
  );
  assert.deepEqual(JSON.parse(h.requests[0].init!.body!), {
    text: "hello world第二段",
    is_merge: true,
  });
});

test("is_merge false is forwarded and suspected labels stay distinct", async () => {
  const body = {
    ...sample,
    labels_ratio: { "0": 0.2, "1": 0.3, "2": 0.5 },
    ratio_confidence: 0.5,
    softmax_confidence: 0.91,
    segment_labels: [
      { text: "也许", label: 2, conf: 0.5, order: 1, position: [0, 2] },
    ],
  };
  const h = harness(body);
  const result = await h.run({ text: "也许", is_merge: false });
  assert.equal(result.suspected_ratio, 0.5);
  assert.equal((result.segments as JsonObject[])[0].label, "suspected");
  assert.match(String(result.summary), /疑似 AI 50\.0%/);
  assert.deepEqual(JSON.parse(h.requests[0].init!.body!), {
    text: "也许",
    is_merge: false,
  });
});

test("text length counts Unicode code points", async () => {
  const h = harness();
  assert.equal((await h.run({ text: "😀".repeat(20000) })).ok, true);
  assert.equal(
    (await h.run({ text: "😀".repeat(20001) })).error_code,
    "invalid_argument",
  );
  assert.equal(h.requests.length, 1);
});

test("invalid input is rejected before a network request", async () => {
  const h = harness();
  for (const input of [
    {},
    { text: " " },
    { text: "" },
    { text: 1 },
    { text: "x", is_merge: "false" },
    { text: "x", is_merge: 0 },
  ] as JsonObject[]) {
    assert.equal((await h.run(input)).error_code, "invalid_argument");
  }
  assert.equal(h.requests.length, 0);
});

test("missing credentials fail explicitly without HTTP", async () => {
  for (const key of [null, "", "   "]) {
    const h = harness(sample, 200, key);
    assert.equal((await h.run({ text: "x" })).error_code, "missing_api_key");
    assert.equal(h.requests.length, 0);
  }
});

for (const [status, code] of [
  [401, "unauthorized"],
  [403, "unauthorized"],
  [429, "rate_limited"],
  [500, "http_error"],
] as const) {
  test(`HTTP ${status} maps to ${code} and redacts the API key`, async () => {
    const h = harness({ msg: "Rejected test-key" }, status);
    const result = await h.run({ text: "x" });
    assert.equal(result.ok, false);
    assert.equal(result.error_code, code);
    assert.equal(result.status_code, status);
    assert.match(String(result.error), /Rejected/);
    assert.doesNotMatch(JSON.stringify([result, h.logs]), /test-key/);
  });
}

test("a non-success status uses msg and does not look like a detection", async () => {
  const h = harness({ status: "error", msg: "quota exceeded" });
  const result = await h.run({ text: "x" });
  assert.equal(result.error_code, "detection_failed");
  assert.equal(result.error, "quota exceeded");
});

test("invalid JSON and malformed success fail explicitly", async () => {
  for (const body of [
    "<html>error</html>",
    { status: "success" },
    { ...sample, labels_ratio: { "0": 1, "1": 0 } },
    {
      ...sample,
      segment_labels: [
        { text: "x", label: 3, conf: 1, order: 1, position: [0, 1] },
      ],
    },
    { ...sample, usage: { total_tokens: -1 } },
  ]) {
    assert.equal(
      (await harness(body).run({ text: "x" })).error_code,
      "invalid_response",
    );
  }
});

test("network and cancellation diagnostics survive", async () => {
  for (const code of ["network", "timeout", "cancelled"]) {
    const h = harness(
      {},
      200,
      "test-key",
      Object.assign(new Error("Failure test-key"), { code }),
    );
    const result = await h.run({ text: "x" });
    assert.equal(result.error_code, code);
    assert.equal(result.error, "Failure ***");
  }
});

test("oversized UTF-8 output fails explicitly rather than truncating text", async () => {
  const h = harness({
    ...sample,
    segment_labels: [
      {
        text: "中".repeat(90000),
        label: 0,
        conf: 0.1,
        order: 1,
        position: [0, 1],
      },
    ],
  });
  assert.equal((await h.run({ text: "x" })).error_code, "result_too_large");
});

test("verifyApiKey classifies a short sample with the draft key", async () => {
  const h = harness();
  assert.deepEqual(await h.actions.get("verifyApiKey")!(), { ok: true });
  assert.equal(h.requests[0].url, endpoint);
  assert.equal(h.requests[0].init?.timeoutMs, 15000);
  assert.equal(h.requests[0].init?.headers?.Authorization, "Bearer test-key");
  assert.deepEqual(JSON.parse(h.requests[0].init!.body!), {
    text: "hello",
    is_merge: true,
  });
});

test("verifyApiKey reports unauthorized without saving the response body to the user", async () => {
  const h = harness({ msg: "bad test-key" }, 401);
  const result = await h.actions.get("verifyApiKey")!();
  assert.equal(result.ok, false);
  assert.equal(result.code, "unauthorized");
  assert.doesNotMatch(String(result.message), /test-key/);
});

test("verifyApiKey keeps host network codes and rejects an empty key", async () => {
  const failed = harness(
    {},
    200,
    "test-key",
    Object.assign(new Error("down"), { code: "timeout" }),
  );
  assert.deepEqual(await failed.actions.get("verifyApiKey")!(), {
    ok: false,
    code: "timeout",
    message: "down",
  });
  const empty = harness(sample, 200, "  ");
  assert.equal(
    (await empty.actions.get("verifyApiKey")!()).code,
    "missing_api_key",
  );
  assert.equal(empty.requests.length, 0);
});
