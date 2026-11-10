import type {
  ActionContext,
  ActionResult,
  PluginServices,
  PluginSetup,
  JsonObject,
  HttpResponse,
} from "reveric-plugin-sdk";
import definitions from "./definitions.json";

const baseUrl = "https://api.specstream.ai/v1";
const failure = (code: string, error: string): JsonObject => ({
  ok: false,
  error_code: code,
  error,
});
const object = (value: unknown): value is JsonObject =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const textLength = (value: string) => [...value].length;
const queryText = (value: unknown): value is string =>
  typeof value === "string" &&
  value.trim().length > 0 &&
  textLength(value) <= 2000;
// QuickJS has no browser URL global. Validate authority here; the API validates the full URL.
const validUrl = (value: unknown): value is string =>
  typeof value === "string" &&
  textLength(value) <= 8192 &&
  /^https?:\/\/[^\s/?#@\\]+(?:[/?#][^\s\\]*)?$/i.test(value);

function validateSearch(input: JsonObject): string | null {
  if (!queryText(input.query))
    return "query must contain 1 to 2000 Unicode characters and cannot be blank";
  if (
    input.max_results !== undefined &&
    (typeof input.max_results !== "number" ||
      !Number.isInteger(input.max_results) ||
      input.max_results < 1 ||
      input.max_results > 50)
  )
    return "max_results must be an integer from 1 to 50";
  if (input.news !== undefined && typeof input.news !== "boolean")
    return "news must be a boolean";
  return null;
}

function redact(value: string, secret: string): string {
  const encoded = JSON.stringify(secret).slice(1, -1);
  return value.split(secret).join("***").split(encoded).join("***");
}

function searchUrl(query: string, count: number, news: boolean): string {
  // speed=fast returns the ranked results with their snippets and no answer.
  return `${baseUrl}/web-search?q=${encodeURIComponent(query)}&num=${count}${
    news ? "&news=true" : "&speed=fast"
  }`;
}

async function request(
  context: PluginServices,
  endpoint: "search" | "extract",
  input: JsonObject,
): Promise<JsonObject> {
  let apiKey = "";
  let response: HttpResponse | undefined;
  const url =
    endpoint === "search"
      ? searchUrl(
          input.query as string,
          input.max_results as number,
          input.news as boolean,
        )
      : `${baseUrl}/extract`;
  try {
    apiKey = (await context.secrets.get("apiKey"))?.trim() ?? "";
    if (!apiKey)
      return failure(
        "missing_api_key",
        "Configure the SpecStream plugin API Key before calling this tool.",
      );
    response =
      endpoint === "search"
        ? await context.http.fetch(url, {
            method: "GET",
            headers: { Authorization: `Bearer ${apiKey}` },
            timeoutMs: 45000,
          })
        : await context.http.fetch(url, {
            method: "POST",
            headers: {
              Authorization: `Bearer ${apiKey}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ urls: [input.url], format: "markdown" }),
            timeoutMs: 45000,
          });
    let data: unknown;
    try {
      data = JSON.parse(response.body);
    } catch {
      /* Raw body is retained in the diagnostic below. */
    }
    const diagnostic = () => ({
      url,
      status: response!.status,
      body: redact(response!.body, apiKey).slice(0, 4096),
      body_truncated: response!.body.length > 4096,
    });
    if (response.status !== 200) {
      const error = object(data) && object(data.error) ? data.error : null;
      const message =
        typeof error?.message === "string"
          ? error.message
          : `SpecStream returned HTTP ${response.status}`;
      const code = typeof error?.code === "string" ? error.code : "http_error";
      context.log.error("SpecStream request failed", diagnostic());
      return {
        ...failure(code, redact(message, apiKey)),
        status_code: response.status,
        diagnostic: diagnostic(),
      };
    }
    const body = object(data) && object(data.data) ? data.data : null;
    const page =
      endpoint === "extract" &&
      Array.isArray(body?.results) &&
      object(body.results[0])
        ? body.results[0]
        : null;
    const valid =
      endpoint === "search"
        ? Array.isArray(body?.sources) &&
          body.sources.every(
            (item) =>
              object(item) &&
              typeof item.title === "string" &&
              typeof item.url === "string" &&
              typeof item.snippet === "string",
          )
        : typeof page?.status === "string" && typeof page.text === "string";
    if (!valid) {
      context.log.error("Invalid SpecStream response", diagnostic());
      return {
        ...failure(
          "invalid_response",
          "SpecStream response does not match the expected result structure.",
        ),
        diagnostic: diagnostic(),
      };
    }
    // The Extract API answers 200 per page; a page it could not read carries its own status.
    if (page && (page.status !== "ok" || !(page.text as string).trim()))
      return failure(
        page.status === "ok" ? "empty" : (page.status as string),
        typeof page.reason === "string"
          ? page.reason
          : `SpecStream could not read the page (${page.status}).`,
      );
    const result: JsonObject =
      endpoint === "search"
        ? {
            ok: true,
            query: input.query as string,
            results: (body!.sources as JsonObject[]).map((item) => ({
              title: item.title,
              url: item.url,
              snippet: item.snippet,
              ...(typeof item.published === "string"
                ? { published: item.published }
                : {}),
            })),
          }
        : {
            ok: true,
            url: typeof page!.url === "string" ? page!.url : String(input.url),
            title: typeof page!.title === "string" ? page!.title : "",
            content: page!.text,
            ...(typeof page!.published === "string"
              ? { published: page!.published }
              : {}),
          };
    // Large results fail explicitly rather than silently dropping page content.
    let bytes = 0;
    for (const ch of JSON.stringify(result)) {
      const code = ch.codePointAt(0)!;
      bytes += code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
      if (bytes > 256 * 1024) break;
    }
    if (bytes > 256 * 1024)
      return failure(
        "result_too_large",
        "SpecStream result exceeds the 256 KiB tool result limit. Search with fewer results or extract a more specific page.",
      );
    return result;
  } catch (error) {
    const message = redact(
      error instanceof Error ? error.message : String(error),
      apiKey || "\u0000",
    );
    const code =
      object(error) && typeof error.code === "string"
        ? error.code
        : "request_failed";
    const diagnostic: JsonObject = {
      url,
      error: message,
      ...(response ? { status: response.status } : {}),
    };
    context.log.error("SpecStream request failed", diagnostic);
    return { ...failure(code, message), diagnostic };
  }
}

/** Runs a one-result search; the settings page may pass an unsaved key. */
async function verifyApiKey(context: ActionContext): Promise<ActionResult> {
  let apiKey = "";
  try {
    apiKey = (await context.secrets.get("apiKey"))?.trim() ?? "";
    if (!apiKey)
      return {
        ok: false,
        code: "missing_api_key",
        message: "API Key is empty",
      };
    const response = await context.http.fetch(
      searchUrl("SpecStream", 1, false),
      {
        method: "GET",
        headers: { Authorization: `Bearer ${apiKey}` },
        timeoutMs: 15000,
      },
    );
    if (response.status === 200) return { ok: true };
    return {
      ok: false,
      code:
        response.status === 401 || response.status === 403
          ? "unauthorized"
          : "http_error",
      message: `SpecStream returned HTTP ${response.status}: ${redact(
        response.body,
        apiKey,
      ).slice(0, 1024)}`,
    };
  } catch (error) {
    return {
      ok: false,
      code:
        object(error) && typeof error.code === "string"
          ? error.code
          : "request_failed",
      message: redact(
        error instanceof Error ? error.message : String(error),
        apiKey || "\u0000",
      ),
    };
  }
}

export function apply(setup: PluginSetup): void {
  setup.settings.registerAction("verifyApiKey", verifyApiKey);
  setup.tools.register({
    ...definitions.SpecStreamSearch,
    display: { summaryArg: "query", result: "items", resultPath: "results" },
    handler: async (input, context) => {
      const invalid = validateSearch(input);
      if (invalid) return failure("invalid_argument", invalid);
      return request(context, "search", {
        query: input.query,
        max_results: input.max_results ?? 10,
        news: input.news ?? false,
      });
    },
  });
  setup.tools.register({
    ...definitions.SpecStreamExtract,
    display: { summaryArg: "url", result: "text", resultPath: "content" },
    handler: async (input, context) =>
      validUrl(input.url)
        ? request(context, "extract", { url: input.url })
        : failure(
            "invalid_argument",
            "url must be an HTTP(S) URL with a host, no credentials, and at most 8192 Unicode characters",
          ),
  });
}
