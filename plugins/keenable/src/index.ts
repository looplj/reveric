import type {
  ActionContext,
  ActionResult,
  PluginServices,
  PluginSetup,
  JsonObject,
  HttpResponse,
} from "reveric-plugin-sdk";
import definitions from "./definitions.json";

// Without an API Key the public endpoints are used; a key only raises rate limits.
const baseUrl = "https://api.keenable.ai/v1";
const appTitle = "Reveric";
const failure = (code: string, error: string): JsonObject => ({
  ok: false,
  error_code: code,
  error,
});
const object = (value: unknown): value is JsonObject =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const textLength = (value: string) => [...value].length;
const nonBlank = (value: unknown): value is string =>
  typeof value === "string" && value.trim().length > 0;
// QuickJS has no browser URL global. Validate authority here; the API validates the full URL.
const validUrl = (value: unknown): value is string =>
  typeof value === "string" &&
  textLength(value) <= 8192 &&
  /^https?:\/\/[^\s/?#@\\]+(?:[/?#][^\s\\]*)?$/i.test(value);

function validateSearch(input: JsonObject): string | null {
  if (!nonBlank(input.query)) return "query cannot be blank";
  if (
    input.max_results !== undefined &&
    (typeof input.max_results !== "number" ||
      !Number.isInteger(input.max_results) ||
      input.max_results < 1 ||
      input.max_results > 50)
  )
    return "max_results must be an integer from 1 to 50";
  if (input.site !== undefined && !nonBlank(input.site))
    return "site must be a non-empty domain";
  if (input.published_after !== undefined && !nonBlank(input.published_after))
    return 'published_after must be a relative time such as "7d" or a date such as "2026-01-01"';
  return null;
}

function redact(value: string, secret: string): string {
  if (!secret) return value;
  const encoded = JSON.stringify(secret).slice(1, -1);
  return value.split(secret).join("***").split(encoded).join("***");
}

function headers(apiKey: string): Record<string, string> {
  return {
    "X-Keenable-Title": appTitle,
    ...(apiKey ? { "X-API-Key": apiKey } : {}),
  };
}

async function request(
  context: PluginServices,
  endpoint: "search" | "fetch",
  input: JsonObject,
): Promise<JsonObject> {
  let apiKey = "";
  let response: HttpResponse | undefined;
  let url = "";
  try {
    apiKey = (await context.secrets.get("apiKey"))?.trim() ?? "";
    url = `${baseUrl}/${endpoint}${apiKey ? "" : "/public"}`;
    response =
      endpoint === "search"
        ? await context.http.fetch(url, {
            method: "POST",
            headers: { ...headers(apiKey), "Content-Type": "application/json" },
            body: JSON.stringify(input),
            timeoutMs: 45000,
          })
        : await context.http.fetch(
            `${url}?url=${encodeURIComponent(String(input.url))}`,
            { method: "GET", headers: headers(apiKey), timeoutMs: 45000 },
          );
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
      const message =
        object(data) && typeof data.message === "string"
          ? data.message
          : `Keenable returned HTTP ${response.status}`;
      const code =
        response.status === 401 || response.status === 403
          ? "unauthorized"
          : response.status === 429
            ? "rate_limited"
            : "http_error";
      context.log.error("Keenable request failed", diagnostic());
      return {
        ...failure(code, redact(message, apiKey)),
        status_code: response.status,
        diagnostic: diagnostic(),
      };
    }
    const valid =
      object(data) &&
      (endpoint === "search"
        ? Array.isArray(data.results) &&
          data.results.every(
            (item) =>
              object(item) &&
              typeof item.title === "string" &&
              typeof item.url === "string" &&
              typeof item.snippet === "string",
          )
        : typeof data.content === "string" && data.content.trim().length > 0);
    if (!valid) {
      context.log.error("Invalid Keenable response", diagnostic());
      return {
        ...failure(
          "invalid_response",
          "Keenable response does not match the expected result structure.",
        ),
        diagnostic: diagnostic(),
      };
    }
    const body = data as JsonObject;
    // `description` is always empty in Keenable responses; `snippet` carries the text.
    const result: JsonObject =
      endpoint === "search"
        ? {
            ok: true,
            query: input.query as string,
            results: (body.results as JsonObject[]).map((item) => ({
              title: item.title,
              url: item.url,
              snippet: item.snippet,
              ...(typeof item.published_at === "string" ||
              typeof item.published_at === "number"
                ? { published_at: item.published_at }
                : {}),
            })),
          }
        : {
            ok: true,
            url: typeof body.url === "string" ? body.url : String(input.url),
            title: typeof body.title === "string" ? body.title : "",
            content: body.content,
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
        "Keenable result exceeds the 256 KiB tool result limit. Search with fewer results or fetch a more specific page.",
      );
    return result;
  } catch (error) {
    const message = redact(
      error instanceof Error ? error.message : String(error),
      apiKey,
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
    context.log.error("Keenable request failed", diagnostic);
    return { ...failure(code, message), diagnostic };
  }
}

/** Runs a one-result keyed search; the settings page may pass an unsaved key. */
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
    const response = await context.http.fetch(`${baseUrl}/search`, {
      method: "POST",
      headers: { ...headers(apiKey), "Content-Type": "application/json" },
      body: JSON.stringify({ query: "Keenable", max_results: 1 }),
      timeoutMs: 15000,
    });
    if (response.status === 200) return { ok: true };
    return {
      ok: false,
      code:
        response.status === 401 || response.status === 403
          ? "unauthorized"
          : "http_error",
      message: `Keenable returned HTTP ${response.status}: ${redact(
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
        apiKey,
      ),
    };
  }
}

export function apply(setup: PluginSetup): void {
  setup.settings.registerAction("verifyApiKey", verifyApiKey);
  setup.tools.register({
    ...definitions.KeenableSearch,
    display: { summaryArg: "query", result: "items", resultPath: "results" },
    handler: async (input, context) => {
      const invalid = validateSearch(input);
      if (invalid) return failure("invalid_argument", invalid);
      return request(context, "search", {
        query: input.query,
        max_results: input.max_results ?? 10,
        ...(input.site !== undefined ? { site: input.site } : {}),
        ...(input.published_after !== undefined
          ? { published_after: input.published_after }
          : {}),
      });
    },
  });
  setup.tools.register({
    ...definitions.KeenableFetch,
    display: { summaryArg: "url", result: "text", resultPath: "content" },
    handler: async (input, context) =>
      validUrl(input.url)
        ? request(context, "fetch", { url: input.url })
        : failure(
            "invalid_argument",
            "url must be an HTTP(S) URL with a host, no credentials, and at most 8192 Unicode characters",
          ),
  });
}
