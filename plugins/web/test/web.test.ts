import { test } from "node:test";
import assert from "node:assert/strict";
import { apply } from "../src/index";
import type {
  PluginSetup,
  ToolContext,
  HttpResponse,
  HttpRequest,
  JsonObject,
  ToolRegistration,
} from "../../sdk/index";
const response = (
  body: string,
  status = 200,
  url = "https://example.com/page",
  headers: Record<string, string> = {},
): HttpResponse => ({ body, status, url, headers });
const article =
  "<html><head><title>作品</title></head><body><h1>作品</h1><p>正文内容 <strong>bold</strong></p><script>secretScript()</script></body></html>";
const searchHtml = `<html><body>
<div class="result c-container" data-tools='{"title":"Reveric 官方文档","url":"https://example.com/docs"}'><h3><a href="https://example.com/docs">Reveric <em>官方</em>文档</a></h3><div class="c-abstract">Reveric 文档、版本说明与使用指南。</div></div>
<div class="result c-container ec_result" data-tools='{"title":"Reveric 推广","url":"https://ads.example.com"}'><h3><a href="https://ads.example.com">广告</a></h3></div>
<div class="result c-container"><h3><a href="https://github.com/looplj/reveric">Reveric GitHub</a></h3><div class="c-abstract">Reveric 源码仓库。</div></div></body></html>`;
function harness(
  fetch: (url: string, init?: HttpRequest) => Promise<HttpResponse>,
) {
  const tools = new Map<string, ToolRegistration>(),
    logs: unknown[] = [];
  const unavailable = async () => {
    throw new Error("M2 API unavailable");
  };
  const plugin = { id: "reveric.web", version: "1.0.0" };
  const log = {
    info: (...args: unknown[]) => {
      logs.push(args);
    },
    warn: (...args: unknown[]) => {
      logs.push(args);
    },
    error: (...args: unknown[]) => {
      logs.push(args);
    },
  };
  const unexpected = () => {
    throw new Error("Unexpected registration");
  };
  const setup: PluginSetup = {
    plugin,
    log,
    tools: {
      register(tool) {
        tools.set(tool.name, tool);
      },
    },
    prompts: { context: unexpected, system: unexpected },
    tasks: { register: unexpected },
    pages: { registerAction: unexpected },
    settings: { registerAction: unexpected },
  };
  apply(setup);
  const context: ToolContext = {
    callId: "test",
    request: { requestId: "test", sessionId: "test", workId: null, agentId: "test", mode: "chat" },
    plugin,
    log,
    http: { fetch },
    storage: { get: unavailable, set: unavailable, remove: unavailable },
    settings: { get: unavailable },
    secrets: { get: unavailable },
    sqlite: { query: unavailable, execute: unavailable, transaction: unavailable },
    chapters: { list: unavailable, get: unavailable, update: unavailable },
    characters: { list: unavailable, get: unavailable, update: unavailable },
  };
  return {
    tools,
    logs,
    run: (name: string, input: JsonObject) =>
      tools.get(name)!.handler(input, context),
  };
}
const hostError = (code: string, message: string) =>
  Object.assign(new Error(message), { code, name: "PluginHostError" });
const baiduHttpRedirect = `<html><head><script>
location.replace(location.href.replace("https://", "http://"));
</script></head><body><noscript><meta http-equiv="refresh" content="0;url=http://www.baidu.com/"></noscript></body></html>`;
test("search follows Baidu's protocol redirect once without losing the query", async () => {
  const urls: string[] = [];
  const result = await harness(async (url, init) => {
    urls.push(url);
    assert.equal(
      init?.headers?.Accept,
      "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    );
    return response(
      urls.length === 1 ? baiduHttpRedirect : searchHtml,
      200,
      url,
    );
  }).run("WebSearch", { query: "DeepSeek 最新消息 & news", limit: 1 });
  assert.equal(urls.length, 2);
  assert.equal(urls[1], urls[0].replace(/^https:/, "http:"));
  assert.match(urls[1], /\/s\?wd=DeepSeek\+/);
  assert.equal(result.ok, true);
  assert.equal((result.results as JsonObject[]).length, 1);
});
test("repeated Baidu protocol redirect stops after two requests", async () => {
  let count = 0;
  const result = await harness(async (url) => {
    count++;
    return response(baiduHttpRedirect, 200, url.replace(/^http:/, "https:"));
  }).run("WebSearch", { query: "test" });
  assert.equal(count, 2);
  assert.equal(result.failure_kind, "invalid_response");
});
test("search does not follow scripts in results or verification pages", async () => {
  for (const body of [
    searchHtml + baiduHttpRedirect,
    "<title>百度安全验证</title>" + baiduHttpRedirect,
  ]) {
    let count = 0;
    const result = await harness(async (url) => {
      count++;
      return response(body, 200, url);
    }).run("WebSearch", { query: "test" });
    assert.equal(count, 1);
    assert.ok(result.ok === true || result.failure_kind === "blocked");
  }
});
test("search only follows the exact script on the Baidu search endpoint", async () => {
  for (const [body, finalUrl] of [
    [baiduHttpRedirect, "https://other.example/s?wd=test"],
    [baiduHttpRedirect, "https://www.baidu.com/link?url=test"],
    [
      baiduHttpRedirect.replace(
        "location.replace(",
        "if (false) location.replace(",
      ),
      "https://www.baidu.com/s?wd=test",
    ],
  ]) {
    let count = 0;
    const result = await harness(async () => {
      count++;
      return response(body, 200, finalUrl);
    }).run("WebSearch", { query: "test" });
    assert.equal(count, 1);
    assert.equal(result.failure_kind, "invalid_response");
  }
});
test("redirected search failures retain the actual target and diagnostics", async () => {
  const urls: string[] = [];
  const result = await harness(async (url) => {
    urls.push(url);
    if (urls.length === 1) return response(baiduHttpRedirect, 200, url);
    throw hostError("network", "HTTP connection failed");
  }).run("WebSearch", { query: "test" });
  assert.equal(urls.length, 2);
  assert.equal(result.failure_kind, "network");
  assert.equal(result.failure_stage, "redirect");
  assert.equal((result.diagnostic as JsonObject).url, urls[1]);
  assert.match(
    String((result.diagnostic as JsonObject).error),
    /HTTP connection failed/,
  );
});
for (const tool of ["WebSearch", "WebFetch"])
  for (const timeout of [false, true]) {
    test(`${tool} keeps failure diagnostics in tool results and host logs (timeout=${timeout})`, async () => {
      const h = harness(async () => {
        if (timeout) throw hostError("timeout", "upstream timed out");
        return response("upstream unavailable", 503);
      });
      const result = await h.run(
        tool,
        tool === "WebSearch"
          ? { query: "test query" }
          : { url: "https://example.com/page" },
      );
      assert.equal(result.ok, false);
      assert.equal(result.error_code, "unavailable");
      assert.match(
        JSON.stringify(result.diagnostic),
        timeout ? /upstream timed out/ : /upstream unavailable/,
      );
      assert.match(
        JSON.stringify(h.logs),
        new RegExp(`\\[${tool}\\] request failed`),
      );
      assert.match(
        JSON.stringify(h.logs),
        timeout ? /upstream timed out/ : /upstream unavailable/,
      );
    });
  }
test("fetch HTTP diagnostics retain upstream details separately from UI text", async () => {
  const h = harness(async () => response("private response", 503));
  const result = await h.run("WebFetch", {
    url: "https://example.com/private?token=secret",
  });
  assert.equal(result.status_code, 503);
  assert.equal(result.failure_kind, "http");
  assert.equal(result.failure_stage, "fetch");
  assert.doesNotMatch(String(result.error), /private response|token=secret/);
  assert.equal((result.diagnostic as JsonObject).body, "private response");
});
test("redirect timeout remains distinct from fetch timeout", async () => {
  const h = harness(async () => {
    throw hostError("timeout", "private uri and body");
  });
  for (const [url, stage] of [
    ["https://www.baidu.com/link?url=secret", "redirect"],
    ["https://example.com/private", "fetch"],
  ]) {
    const result = await h.run("WebFetch", { url });
    assert.equal(result.failure_kind, "timeout");
    assert.equal(result.failure_stage, stage);
    assert.doesNotMatch(String(result.error), /private uri and body/);
    assert.match(JSON.stringify(result.diagnostic), /private uri and body/);
  }
});
for (const [label, body, kind] of [
  [
    "verification",
    "<html><title>百度安全验证</title><body>请输入验证码</body></html>",
    "blocked",
  ],
  [
    "unknown",
    "<html><body>Unexpected search layout</body></html>",
    "invalid_response",
  ],
]) {
  test(`search reports ${label}`, async () => {
    const result = await harness(async () => response(body)).run("WebSearch", {
      query: "test",
    });
    assert.equal(result.ok, false);
    assert.equal(result.failure_kind, kind);
    assert.equal(result.failure_stage, "parse");
    assert.equal(result.results, undefined);
  });
}
test("explicit no-results page is successful", async () => {
  const result = await harness(async () =>
    response(
      '<html><div class="nors"><p>抱歉，没有找到与“test”相关的网页。</p></div></html>',
    ),
  ).run("WebSearch", { query: "test" });
  assert.deepEqual(result.results, []);
  assert.equal(result.ok, true);
  assert.equal(result.error, undefined);
});
for (const [label, body, kind] of [
  ["empty", "<html><body></body></html>", "empty_content"],
  [
    "title-only",
    '<html><title>百度百科</title><body><div id="root"></div><script>render()</script></body></html>',
    "empty_content",
  ],
  [
    "noscript",
    '<html><head><title>App</title></head><body><noscript>You need JavaScript.</noscript><div id="root"></div><script src="app.js"></script></body></html>',
    "empty_content",
  ],
  [
    "heading-only",
    "<html><title>百度百科</title><body><h1>百度百科</h1></body></html>",
    "empty_content",
  ],
  [
    "DuckDuckGo",
    "<html><title>DuckDuckGo</title><body>Unfortunately, bots use DuckDuckGo too. Please complete the following challenge to confirm this search was made by a human.</body></html>",
    "blocked",
  ],
  [
    "Douban",
    '<html><title>豆瓣</title><body>载入中<form id="sec"><input id="cha"><input id="sol"></form><script>async function sha512() {}</script></body></html>',
    "blocked",
  ],
]) {
  test(`fetch rejects ${label} without content-type`, async () => {
    const result = await harness(async () => response(body)).run("WebFetch", {
      url: "https://example.com/?token=secret",
    });
    assert.equal(result.ok, false);
    assert.equal(result.failure_kind, kind);
    assert.equal(result.failure_stage, "parse");
    assert.equal(result.content, undefined);
    assert.doesNotMatch(String(result.error), /token=secret/);
  });
}
test("UTF-8 HTML without MIME converts and removes scripts", async () => {
  const result = await harness(async () => response(article)).run("WebFetch", {
    url: "https://example.com/page",
  });
  assert.equal(result.title, "作品");
  assert.match(String(result.content), /# 作品/);
  assert.match(String(result.content), /正文内容/);
  assert.match(String(result.content), /\*\*bold\*\*/);
  assert.doesNotMatch(String(result.content), /secretScript/);
  assert.equal(result.format, "markdown");
});
test("short text and articles discussing verification remain readable", async () => {
  for (const body of [
    "短正文",
    "<html><title>验证码原理</title><body><h1>验证码原理</h1><p>百度安全验证和 DuckDuckGo challenge 的介绍。</p></body></html>",
  ]) {
    const result = await harness(async () => response(body)).run("WebFetch", {
      url: "https://example.com/page",
    });
    assert.equal(result.error, undefined);
    assert.ok(result.content);
  }
});
test("blocked Baidu redirect stops after one request", async () => {
  let count = 0;
  const result = await harness(async () => {
    count++;
    return response(
      "<html><title>百度安全验证</title><body>验证码</body></html>",
    );
  }).run("WebFetch", { url: "https://www.baidu.com/link?url=secret" });
  assert.equal(result.failure_kind, "blocked");
  assert.equal(result.failure_stage, "redirect");
  assert.equal(count, 1);
});
test("search request preserves query, language and filters ads", async () => {
  const h = harness(async (url, init) => {
    assert.equal(url, "https://www.baidu.com/s?wd=Riverpod+AsyncNotifier+docs");
    assert.match(init!.headers!["Accept-Language"], /zh-CN/);
    return response(searchHtml);
  });
  const result = await h.run("WebSearch", {
    query: "Riverpod AsyncNotifier docs",
    limit: 3,
  });
  assert.equal(result.engine, "baidu");
  assert.deepEqual(result.results, [
    {
      title: "Reveric 官方文档",
      url: "https://example.com/docs",
      snippet: "Reveric 文档、版本说明与使用指南。",
    },
    {
      title: "Reveric GitHub",
      url: "https://github.com/looplj/reveric",
      snippet: "Reveric 源码仓库。",
    },
  ]);
});
for (const redirect of [
  '<script>window.location.replace("https://example.com/page")</script>',
  '<script>window.location.href = "https://example.com/page"</script>',
  '<meta http-equiv="refresh" content="0;URL=\'https://example.com/page\'">',
  String.raw`<script>location.assign("https:\/\/example.com\/page")</script>`,
]) {
  test(`resolves redirect ${redirect.slice(0, 32)}`, async () => {
    const urls: string[] = [];
    const result = await harness(async (url, init) => {
      urls.push(url);
      if (url.includes("baidu.com")) return response(redirect, 200, url);
      assert.match(init!.headers!.Accept, /text\/markdown/);
      return response(article, 200, url);
    }).run("WebFetch", { url: "http://www.baidu.com/link?url=redirected" });
    assert.deepEqual(urls, [
      "http://www.baidu.com/link?url=redirected",
      "https://example.com/page",
    ]);
    assert.equal(result.resolved_url, "https://example.com/page");
    assert.equal(result.url, result.resolved_url);
    assert.match(String(result.content), /正文内容/);
  });
}
test("unavailable redirect returns immediately", async () => {
  let count = 0;
  const result = await harness(async () => {
    count++;
    return response("出错啦", 404);
  }).run("WebFetch", { url: "http://www.baidu.com/link?url=missing" });
  assert.equal(count, 1);
  assert.equal(result.error, "Baidu redirect URL is unavailable. HTTP 404.");
  assert.equal(result.status_code, 404);
  assert.equal(result.url, "http://www.baidu.com/link?url=missing");
});
test("invalid inputs, result limit, truncation and host limits", async () => {
  const h = harness(async () => response(searchHtml));
  for (const input of [
    { query: "" },
    { query: "x", limit: "bad" },
    { query: "x", limit: true },
  ] as JsonObject[])
    assert.equal(
      (await h.run("WebSearch", input)).error_code,
      "invalid_argument",
    );
  assert.equal(
    (
      (await h.run("WebSearch", { query: "x", limit: "1.9" }))
        .results as unknown[]
    ).length,
    1,
  );
  for (const url of ["", "file:///private"])
    assert.equal(
      (await h.run("WebFetch", { url })).error_code,
      "invalid_argument",
    );
  const result = await harness(async () => response("x".repeat(11000))).run(
    "WebFetch",
    { url: "https://example.com" },
  );
  assert.equal(result.truncated, true);
  assert.equal(result.returned_chars, 10240);
  assert.equal(result.total_chars, 11000);
  assert.match(String(result.warning), /10240/);
  for (const code of ["too_large", "network", "cancelled"]) {
    const failure = await harness(async () => {
      throw hostError(code, "details");
    }).run("WebFetch", { url: "https://example.com" });
    assert.equal(failure.failure_kind, code);
    assert.equal(
      failure.error_code,
      code === "too_large" ? "resource_exhausted" : "unavailable",
    );
  }
});
test("registration display and HTTP redirected final address", async () => {
  const h = harness(async () =>
    response(article, 200, "https://example.org/final"),
  );
  assert.deepEqual(h.tools.get("WebSearch")!.display, {
    summaryArg: "query",
    result: "items",
    resultPath: "results",
  });
  assert.deepEqual(h.tools.get("WebFetch")!.display, {
    summaryArg: "url",
    result: "text",
    resultPath: "content",
  });
  assert.equal(
    (await h.run("WebFetch", { url: "https://example.com" })).url,
    "https://example.org/final",
  );
});

test("query coercion and whitespace remain compatible", async () => {
  const urls: string[] = [];
  const h = harness(async (url) => {
    urls.push(url);
    return response(searchHtml);
  });
  assert.equal((await h.run("WebSearch", { query: 123 })).query, "123");
  assert.equal(
    (await h.run("WebSearch", { query: "  query  " })).query,
    "  query  ",
  );
  assert.equal(urls[1], "https://www.baidu.com/s?wd=++query++");
});

test("numeric strings and bounds preserve old tool coercion", async () => {
  const html = Array.from(
    { length: 15 },
    (_, i) =>
      `<div class="result"><h3><a href="https://example.com/${i}">Result ${i}</a></h3></div>`,
  ).join("");
  const h = harness(async () => response(html));
  assert.equal(
    (
      (await h.run("WebSearch", { query: "test", limit: "5" }))
        .results as unknown[]
    ).length,
    5,
  );
  assert.equal(
    (
      (await h.run("WebSearch", { query: "test", limit: "30" }))
        .results as unknown[]
    ).length,
    10,
  );
  assert.equal(
    (await h.run("WebSearch", { query: "test", limit: "many" })).error,
    "limit must be a number",
  );
});

for (const wrapper of [
  "div",
  'div class="c-abstract"',
  'div class="content-right_8Zs40"',
]) {
  test(`search removes scripts and styles from ${wrapper} snippets`, async () => {
    const html = `<div class="result"><h3><a href="https://example.com">Title</a></h3><${wrapper}>Visible summary<script>trackingSecret()</script><style>.secret{display:none}</style></div></div>`;
    const result = await harness(async () => response(html)).run("WebSearch", {
      query: "test",
    });
    assert.deepEqual(result.results, [
      {
        title: "Title",
        url: "https://example.com",
        snippet: "Visible summary",
      },
    ]);
  });
}
test("images resolve against the final page URL and preserve absolute URLs", async () => {
  const html = `<html><body><p>Article</p>
    <img alt="root" src="/images/a.png">
    <img alt="relative" src="../images/b.png?x=1&amp;y=2">
    <img alt="protocol" src="//cdn.example.com/c.png">
    <img alt="absolute" src="https://cdn.example.com/d.png">
    <img alt="data" src="data:image/png;base64,AAAA">
    </body></html>`;
  const result = await harness(async () =>
    response(html, 200, "https://final.example.com/articles/page"),
  ).run("WebFetch", { url: "https://original.example.com" });
  const content = String(result.content);
  for (const url of [
    "https://final.example.com/images/a.png",
    "https://final.example.com/images/b.png?x=1&y=2",
    "https://cdn.example.com/c.png",
    "https://cdn.example.com/d.png",
  ]) {
    assert.ok(content.includes(url), content);
  }
  assert.doesNotMatch(content, /data:image/);
});
test("images honor document base and tolerate malformed image URLs", async () => {
  const html =
    '<html><head><base href="../assets/"></head><body><p>Article</p><img alt="photo" src="photo.png"><img src="http://["></body></html>';
  const result = await harness(async () =>
    response(html, 200, "https://example.com/articles/page"),
  ).run("WebFetch", { url: "https://example.com/start" });
  assert.equal(result.ok, true);
  assert.match(
    String(result.content),
    /https:\/\/example.com\/assets\/photo.png/,
  );
});
test("relative images preserve IPv6 authorities and ports", async () => {
  const result = await harness(async () =>
    response(
      '<html><body><p>Article</p><img src="../photo.png"></body></html>',
      200,
      "https://[::1]:8443/articles/page",
    ),
  ).run("WebFetch", { url: "https://example.com/start" });
  assert.ok(String(result.content).includes("https://[::1]:8443/photo.png"));
});
test("HTTP diagnostics retain status and mark bounded response excerpts", async () => {
  const result = await harness(async () => response("x".repeat(500), 403)).run(
    "WebSearch",
    { query: "test" },
  );
  assert.equal(result.status_code, 403);
  assert.equal((result.diagnostic as JsonObject).status, 403);
  assert.equal((result.diagnostic as JsonObject).body, "x".repeat(400));
  assert.equal((result.diagnostic as JsonObject).body_truncated, true);
});
for (const message of [
  "DNS lookup failed: ENOTFOUND example.com",
  "TLS handshake failed: CERT_HAS_EXPIRED",
]) {
  test(`network diagnostic reaches the agent: ${message}`, async () => {
    for (const tool of ["WebSearch", "WebFetch"]) {
      const result = await harness(async () => {
        throw hostError("network", message);
      }).run(
        tool,
        tool === "WebSearch"
          ? { query: "test" }
          : { url: "https://example.com" },
      );
      assert.equal(result.failure_kind, "network");
      assert.match(
        String((result.diagnostic as JsonObject).error),
        new RegExp(message),
      );
      assert.doesNotMatch(String(result.error), /ENOTFOUND|CERT_HAS_EXPIRED/);
    }
  });
}
