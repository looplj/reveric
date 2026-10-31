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
} from "../../sdk/index";
import { apply } from "../src/index";

const item = {
  title: "Title",
  url: "https://example.com",
  snippet: "Snippet",
  summary: "Summary",
  content: "Content",
  date: null,
  site_name: "Example",
  site_icon: null,
  authority: 3,
  rerank_score: 2.4,
};
function harness(
  body: unknown = { results: [item] },
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
  const plugin = { id: "reveric.deepseek", version: "1.0.0" };
  const services: PluginServices = {
    plugin,
    sqlite: { query: unavailable, execute: unavailable, transaction: unavailable },
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
    log: services.log,
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
    request: { requestId: "test", sessionId: "test", workId: null, agentId: "test", mode: "chat" },
    chapters: { list: unavailable, get: unavailable, update: unavailable },
    characters: { list: unavailable, get: unavailable, update: unavailable },
  };
  return {
    tools,
    actions,
    requests,
    logs,
    run: (tool: string, input: JsonObject) =>
      tools.get(tool)!.handler(input, context),
  };
}

test("registers independent tools without reading credentials during apply", () => {
  const h = harness();
  assert.deepEqual([...h.tools.keys()], ["DeepSeekSearch", "DeepSeekFetch"]);
  assert.deepEqual([...h.actions.keys()], ["verifyApiKey"]);
  assert.equal(h.requests.length, 0);
});
test("verifyApiKey succeeds when the model list accepts the key", async () => {
  const h = harness({ object: "list", data: [] });
  assert.deepEqual(await h.actions.get("verifyApiKey")!(), { ok: true });
  assert.equal(h.requests[0].url, "https://api.deepseek.com/models");
  assert.equal(h.requests[0].init?.method, "GET");
  assert.equal(h.requests[0].init?.headers?.Authorization, "Bearer test-key");
});
for (const [status, code] of [
  [401, "unauthorized"],
  [403, "unauthorized"],
  [429, "http_error"],
  [500, "http_error"],
] as const) {
  test(`verifyApiKey maps HTTP ${status} to ${code} and redacts the key`, async () => {
    const h = harness({ error: { message: "Bad test-key" } }, status);
    const result = await h.actions.get("verifyApiKey")!();
    assert.equal(result.ok, false);
    assert.equal(result.code, code);
    assert.match(String(result.message), new RegExp(`HTTP ${status}`));
    assert.doesNotMatch(String(result.message), /test-key/);
  });
}
test("verifyApiKey keeps host network and timeout codes", async () => {
  for (const code of ["network", "timeout"]) {
    const h = harness(
      {},
      200,
      "test-key",
      Object.assign(new Error("Failure test-key"), { code }),
    );
    assert.deepEqual(await h.actions.get("verifyApiKey")!(), {
      ok: false,
      code,
      message: "Failure ***",
    });
  }
});
test("verifyApiKey without a key fails without HTTP", async () => {
  const h = harness({}, 200, "  ");
  assert.equal((await h.actions.get("verifyApiKey")!()).code, "missing_api_key");
  assert.equal(h.requests.length, 0);
});
test("search forwards official arguments and preserves official result fields", async () => {
  const h = harness();
  const input = {
    query: "DeepSeek site:example.com lang:en",
    count: 50,
    ori_question: "Original question",
    localization: "1.1.1.1",
    need_content: true,
  };
  assert.deepEqual(await h.run("DeepSeekSearch", input), {
    ok: true,
    results: [item],
  });
  assert.equal(h.requests[0].url, "https://api.deepseek.com/v1/tools/search");
  assert.equal(h.requests[0].init?.method, "POST");
  assert.equal(h.requests[0].init?.headers?.Authorization, "Bearer test-key");
  assert.deepEqual(JSON.parse(h.requests[0].init!.body!), input);
});
test("search defaults match the API and null original question is omitted", async () => {
  const h = harness({ results: [] });
  assert.deepEqual(
    await h.run("DeepSeekSearch", { query: "hello", ori_question: null }),
    { ok: true, results: [] },
  );
  assert.deepEqual(JSON.parse(h.requests[0].init!.body!), {
    query: "hello",
    count: 10,
    need_content: false,
  });
});
test("query length counts Unicode code points", async () => {
  const h = harness();
  assert.equal(
    (await h.run("DeepSeekSearch", { query: "😀".repeat(128) })).ok,
    true,
  );
  assert.equal(
    (await h.run("DeepSeekSearch", { query: "😀".repeat(129) })).error_code,
    "invalid_argument",
  );
  assert.equal(h.requests.length, 1);
});
test("invalid input is rejected before a network request", async () => {
  const h = harness();
  for (const input of [
    { query: " " },
    { query: 1 },
    { query: "x", count: 0 },
    { query: "x", count: 51 },
    { query: "x", count: 1.1 },
    { query: "x", count: "5" },
    { query: "x", ori_question: "" },
    { query: "x", need_content: "true" },
    { query: "x", localization: 1 },
  ] as JsonObject[]) {
    assert.equal(
      (await h.run("DeepSeekSearch", input)).error_code,
      "invalid_argument",
    );
  }
  for (const url of [
    "file:///tmp/a",
    "https://",
    "https://user:password@example.com",
    "https://example.com/with space",
    "https://example.com/" + "a".repeat(8192),
  ]) {
    assert.equal(
      (await h.run("DeepSeekFetch", { url })).error_code,
      "invalid_argument",
    );
  }
  assert.equal(h.requests.length, 0);
});
test("fetch returns Markdown without modification", async () => {
  const h = harness({ title: "Article", content: "# Title\n\n中文正文" });
  assert.deepEqual(
    await h.run("DeepSeekFetch", { url: "https://example.com/page?q=1" }),
    { ok: true, title: "Article", content: "# Title\n\n中文正文" },
  );
  assert.equal(h.requests[0].url, "https://api.deepseek.com/v1/tools/fetch");
  assert.deepEqual(JSON.parse(h.requests[0].init!.body!), {
    url: "https://example.com/page?q=1",
  });
});
test("missing credentials fail explicitly without HTTP", async () => {
  for (const key of [null, "", "   "]) {
    const h = harness({}, 200, key);
    assert.equal(
      (await h.run("DeepSeekSearch", { query: "x" })).error_code,
      "missing_api_key",
    );
    assert.equal(h.requests.length, 0);
  }
});
for (const status of [400, 401, 402, 403, 404, 408, 429, 500, 504]) {
  test(`HTTP ${status} retains diagnostics and redacts the API key`, async () => {
    const h = harness(
      { error: { code: "upstream_error", message: "Rejected test-key" } },
      status,
    );
    const result = await h.run("DeepSeekSearch", { query: "x" });
    assert.equal(result.ok, false);
    assert.equal(result.status_code, status);
    assert.equal(result.error_code, "upstream_error");
    assert.match(String(result.error), /Rejected/);
    assert.doesNotMatch(JSON.stringify([result, h.logs]), /test-key/);
    assert.equal(h.requests.length, 1);
  });
}
test("invalid JSON and malformed success fail explicitly", async () => {
  for (const body of [
    "<html>error</html>",
    { results: "wrong" },
    { results: [{ title: "missing fields" }] },
  ]) {
    assert.equal(
      (await harness(body).run("DeepSeekSearch", { query: "x" })).error_code,
      "invalid_response",
    );
  }
  assert.equal(
    (
      await harness({ title: "empty", content: " " }).run("DeepSeekFetch", {
        url: "https://example.com",
      })
    ).error_code,
    "invalid_response",
  );
});
test("network and cancellation diagnostics survive", async () => {
  for (const code of ["network", "timeout", "cancelled"]) {
    const h = harness(
      {},
      200,
      "test-key",
      Object.assign(new Error("Failure test-key"), { code }),
    );
    const result = await h.run("DeepSeekSearch", { query: "x" });
    assert.equal(result.error_code, code);
    assert.equal(result.error, "Failure ***");
  }
});
test("oversized UTF-8 output fails explicitly rather than truncating content", async () => {
  const h = harness({ title: "large", content: "中".repeat(90000) });
  assert.equal(
    (await h.run("DeepSeekFetch", { url: "https://example.com" })).error_code,
    "result_too_large",
  );
});
