import type {
  ActionContext,
  ActionResult,
  PluginServices,
  PluginSetup,
  JsonObject,
  HttpResponse,
} from "../../sdk/index";
import definitions from "./definitions.json";

const baseUrl = "https://api.deepseek.com/v1/tools";
const modelsUrl = "https://api.deepseek.com/models";
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
  textLength(value) <= 128;
// QuickJS has no browser URL global. Validate authority here; the API validates the full URL.
const validUrl = (value: unknown): value is string =>
  typeof value === "string" &&
  textLength(value) <= 8192 &&
  /^https?:\/\/[^\s/?#@\\]+(?:[/?#][^\s\\]*)?$/i.test(value);

function validateSearch(input: JsonObject): string | null {
  if (!queryText(input.query))
    return "query must contain 1 to 128 Unicode characters and cannot be blank";
  if (
    input.count !== undefined &&
    (typeof input.count !== "number" ||
      !Number.isInteger(input.count) ||
      input.count < 1 ||
      input.count > 50)
  )
    return "count must be an integer from 1 to 50";
  if (input.ori_question != null && !queryText(input.ori_question))
    return "ori_question must contain 1 to 128 Unicode characters";
  if (
    input.localization !== undefined &&
    typeof input.localization !== "string"
  )
    return "localization must be a string";
  if (
    input.need_content !== undefined &&
    typeof input.need_content !== "boolean"
  )
    return "need_content must be a boolean";
  return null;
}

function redact(value: string, secret: string): string {
  const encoded = JSON.stringify(secret).slice(1, -1);
  return value.split(secret).join("***").split(encoded).join("***");
}

async function request(
  context: PluginServices,
  endpoint: "search" | "fetch",
  input: JsonObject,
): Promise<JsonObject> {
  let apiKey = "";
  let response: HttpResponse | undefined;
  const url = `${baseUrl}/${endpoint}`;
  try {
    apiKey = (await context.secrets.get("apiKey"))?.trim() ?? "";
    if (!apiKey)
      return failure(
        "missing_api_key",
        "Configure the DeepSeek plugin API Key before calling this tool.",
      );
    response = await context.http.fetch(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(input),
      timeoutMs: 45000,
    });
    let data: unknown;
    try {
      data = JSON.parse(response.body);
    } catch {
      /* Raw body is retained in the diagnostic below. */
    }
    if (response.status !== 200) {
      const error = object(data) && object(data.error) ? data.error : null;
      const message =
        typeof error?.message === "string"
          ? error.message
          : `DeepSeek returned HTTP ${response.status}`;
      const code = typeof error?.code === "string" ? error.code : "http_error";
      const diagnostic = {
        url,
        status: response.status,
        body: redact(response.body, apiKey).slice(0, 4096),
        body_truncated: response.body.length > 4096,
      };
      context.log.error("DeepSeek request failed", diagnostic);
      return {
        ...failure(code, redact(message, apiKey)),
        status_code: response.status,
        diagnostic,
      };
    }
    if (
      !object(data) ||
      (endpoint === "search"
        ? !Array.isArray(data.results) ||
          data.results.some(
            (item) =>
              !object(item) ||
              typeof item.title !== "string" ||
              typeof item.url !== "string" ||
              typeof item.snippet !== "string" ||
              typeof item.summary !== "string" ||
              typeof item.content !== "string",
          )
        : typeof data.title !== "string" ||
          typeof data.content !== "string" ||
          !data.content.trim())
    ) {
      const diagnostic = {
        url,
        status: response.status,
        body: redact(response.body, apiKey).slice(0, 4096),
        body_truncated: response.body.length > 4096,
      };
      context.log.error("Invalid DeepSeek response", diagnostic);
      return {
        ...failure(
          "invalid_response",
          "DeepSeek response does not match the expected result structure.",
        ),
        diagnostic,
      };
    }
    const result: JsonObject = { ...data, ok: true };
    // Keep the full official response when it fits the host's 256 KiB result budget.
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
        "DeepSeek result exceeds the 256 KiB tool result limit. Search with fewer results or need_content=false; fetch a more specific page.",
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
    context.log.error("DeepSeek request failed", diagnostic);
    return { ...failure(code, message), diagnostic };
  }
}

/** Checks the key against the lightweight model list; the settings page may pass an unsaved key. */
async function verifyApiKey(context: ActionContext): Promise<ActionResult> {
  let apiKey = "";
  try {
    apiKey = (await context.secrets.get("apiKey"))?.trim() ?? "";
    if (!apiKey)
      return { ok: false, code: "missing_api_key", message: "API Key is empty" };
    const response = await context.http.fetch(modelsUrl, {
      method: "GET",
      headers: { Authorization: `Bearer ${apiKey}` },
      timeoutMs: 15000,
    });
    if (response.status === 200) return { ok: true };
    return {
      ok: false,
      code:
        response.status === 401 || response.status === 403
          ? "unauthorized"
          : "http_error",
      message: `DeepSeek returned HTTP ${response.status}: ${redact(
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
    ...definitions.DeepSeekSearch,
    display: { summaryArg: "query", result: "items", resultPath: "results" },
    handler: async (input, context) => {
      const invalid = validateSearch(input);
      if (invalid) return failure("invalid_argument", invalid);
      return request(context, "search", {
        query: input.query,
        count: input.count ?? 10,
        ...(input.ori_question != null
          ? { ori_question: input.ori_question }
          : {}),
        ...(input.localization !== undefined
          ? { localization: input.localization }
          : {}),
        need_content: input.need_content ?? false,
      });
    },
  });
  setup.tools.register({
    ...definitions.DeepSeekFetch,
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
