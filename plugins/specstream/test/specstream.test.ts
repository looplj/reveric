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

const source = {
  url: "https://example.com",
  title: "Title",
  site: "example.com",
  snippet: "Snippet",
  cited: false,
  published: "2026-01-02",
};
const page = {
  url: "https://example.com/page?q=1",
  status: "ok",
  title: "Article",
  text: "# Title\n\n中文正文",
  published: "2026-01-02",
};
function harness(
  body: unknown = { data: { query: "x", sources: [source] } },
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
  const plugin = { id: "reveric.specstream", version: "1.0.0" };
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
    run: (tool: string, input: JsonObject) =>
      tools.get(tool)!.handler(input, context),
  };
}

test("registers independent tools without reading credentials during apply", () => {
  const h = harness();
  assert.deepEqual(
    [...h.tools.keys()],
    ["SpecStreamSearch", "SpecStreamExtract"],
  );
  assert.deepEqual([...h.actions.keys()], ["verifyApiKey"]);
  assert.equal(h.requests.length, 0);
});
test("search sends a bearer GET and maps sources to results", async () => {
  const h = harness();
  assert.deepEqual(await h.run("SpecStreamSearch", { query: "中文 search" }), {
    ok: true,
    query: "中文 search",
    results: [
      {
        title: "Title",
        url: "https://example.com",
        snippet: "Snippet",
        published: "2026-01-02",
      },
    ],
  });
  assert.equal(
    h.requests[0].url,
    "https://api.specstream.ai/v1/web-search?q=%E4%B8%AD%E6%96%87%20search&num=10&speed=fast",
  );
  assert.equal(h.requests[0].init?.method, "GET");
  assert.equal(h.requests[0].init?.headers?.Authorization, "Bearer test-key");
});
test("search forwards max_results and news", async () => {
  const h = harness();
  const input = { query: "SpecStream", max_results: 50, news: true };
  assert.equal((await h.run("SpecStreamSearch", input)).ok, true);
  assert.equal(
    h.requests[0].url,
    "https://api.specstream.ai/v1/web-search?q=SpecStream&num=50&news=true",
  );
});
test("results without published omit the field", async () => {
  const h = harness({
    data: { sources: [{ ...source, published: null }] },
  });
  const result = await h.run("SpecStreamSearch", { query: "x" });
  assert.deepEqual((result.results as JsonObject[])[0], {
    title: "Title",
    url: "https://example.com",
    snippet: "Snippet",
  });
});
test("a missing key fails before a network request", async () => {
  for (const key of [null, "", "   "]) {
    const h = harness(undefined, 200, key);
    assert.equal(
      (await h.run("SpecStreamSearch", { query: "x" })).error_code,
      "missing_api_key",
    );
    assert.equal(
      (await h.run("SpecStreamExtract", { url: "https://example.com" }))
        .error_code,
      "missing_api_key",
    );
    assert.equal(h.requests.length, 0);
  }
});
test("invalid input is rejected before a network request", async () => {
  const h = harness();
  for (const input of [
    { query: " " },
    { query: 1 },
    { query: "x".repeat(2001) },
    { query: "x", max_results: 0 },
    { query: "x", max_results: 51 },
    { query: "x", max_results: 1.1 },
    { query: "x", max_results: "5" },
    { query: "x", news: "yes" },
  ] as JsonObject[]) {
    assert.equal(
      (await h.run("SpecStreamSearch", input)).error_code,
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
      (await h.run("SpecStreamExtract", { url })).error_code,
      "invalid_argument",
    );
  }
  assert.equal(h.requests.length, 0);
});
test("extract posts the URL and returns Markdown", async () => {
  const h = harness({ data: { request_id: "r", results: [page] } });
  assert.deepEqual(
    await h.run("SpecStreamExtract", { url: "https://example.com/page?q=1" }),
    {
      ok: true,
      url: "https://example.com/page?q=1",
      title: "Article",
      content: "# Title\n\n中文正文",
      published: "2026-01-02",
    },
  );
  assert.equal(h.requests[0].url, "https://api.specstream.ai/v1/extract");
  assert.equal(h.requests[0].init?.method, "POST");
  assert.equal(h.requests[0].init?.headers?.Authorization, "Bearer test-key");
  assert.deepEqual(JSON.parse(h.requests[0].init!.body!), {
    urls: ["https://example.com/page?q=1"],
    format: "markdown",
  });
});
test("a page the Extract API could not read fails with its status", async () => {
  const h = harness({
    data: {
      results: [{ ...page, status: "blocked", text: "", reason: "Blocked" }],
    },
  });
  assert.deepEqual(
    await h.run("SpecStreamExtract", { url: "https://example.com" }),
    { ok: false, error_code: "blocked", error: "Blocked" },
  );
});
for (const [status, code] of [
  [400, "bad_request"],
  [401, "invalid_token"],
  [429, "rate_limited"],
  [503, "capacity"],
] as const) {
  test(`HTTP ${status} keeps the error code ${code}, diagnostics and redacts the key`, async () => {
    const h = harness(
      { error: { code, message: "Rejected test-key" } },
      status,
    );
    const result = await h.run("SpecStreamSearch", { query: "x" });
    assert.equal(result.ok, false);
    assert.equal(result.status_code, status);
    assert.equal(result.error_code, code);
    assert.match(String(result.error), /Rejected/);
    assert.doesNotMatch(JSON.stringify([result, h.logs]), /test-key/);
    assert.equal(h.requests.length, 1);
  });
}
test("an error without an envelope maps to http_error", async () => {
  const result = await harness("<html>bad gateway</html>", 502).run(
    "SpecStreamSearch",
    { query: "x" },
  );
  assert.equal(result.error_code, "http_error");
  assert.equal(result.error, "SpecStream returned HTTP 502");
});
test("invalid JSON and malformed success fail explicitly", async () => {
  for (const body of [
    "<html>error</html>",
    { data: { sources: "wrong" } },
    { data: { sources: [{ title: "missing fields" }] } },
    { sources: [source] },
  ]) {
    assert.equal(
      (await harness(body).run("SpecStreamSearch", { query: "x" })).error_code,
      "invalid_response",
    );
  }
  assert.equal(
    (
      await harness({ data: { results: [] } }).run("SpecStreamExtract", {
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
    const result = await h.run("SpecStreamSearch", { query: "x" });
    assert.equal(result.error_code, code);
    assert.equal(result.error, "Failure ***");
  }
});
test("oversized UTF-8 output fails explicitly rather than truncating content", async () => {
  const h = harness({
    data: { results: [{ ...page, text: "中".repeat(90000) }] },
  });
  assert.equal(
    (await h.run("SpecStreamExtract", { url: "https://example.com" }))
      .error_code,
    "result_too_large",
  );
});
test("verifyApiKey runs a one-result search", async () => {
  const h = harness();
  assert.deepEqual(await h.actions.get("verifyApiKey")!(), { ok: true });
  assert.equal(
    h.requests[0].url,
    "https://api.specstream.ai/v1/web-search?q=SpecStream&num=1&speed=fast",
  );
  assert.equal(h.requests[0].init?.headers?.Authorization, "Bearer test-key");
});
for (const [status, code] of [
  [401, "unauthorized"],
  [403, "unauthorized"],
  [500, "http_error"],
] as const) {
  test(`verifyApiKey maps HTTP ${status} to ${code} and redacts the key`, async () => {
    const h = harness({ message: "Bad test-key" }, status);
    const result = await h.actions.get("verifyApiKey")!();
    assert.equal(result.ok, false);
    assert.equal(result.code, code);
    assert.match(String(result.message), new RegExp(`HTTP ${status}`));
    assert.doesNotMatch(String(result.message), /test-key/);
  });
}
test("verifyApiKey reports an empty key without a request", async () => {
  const h = harness(undefined, 200, " ");
  assert.equal(
    (await h.actions.get("verifyApiKey")!()).code,
    "missing_api_key",
  );
  assert.equal(h.requests.length, 0);
});
