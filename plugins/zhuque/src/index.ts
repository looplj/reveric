import type {
  ActionContext,
  ActionResult,
  PluginServices,
  PluginSetup,
  JsonObject,
  HttpResponse,
} from "reveric-plugin-sdk";
import definitions from "./definitions.json";

const endpoint =
  "https://ai-gateway.edgeone.link/v1/providers/zhuque-text/classify";
const maxTextLength = 20000;
const verifyText = "hello";
const resultLimit = 256 * 1024;
const failure = (code: string, error: string): JsonObject => ({
  ok: false,
  error_code: code,
  error,
});
const object = (value: unknown): value is JsonObject =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const textLength = (value: string) => [...value].length;
const finite = (value: unknown): value is number =>
  typeof value === "number" && Number.isFinite(value);
const integer = (value: unknown): value is number =>
  typeof value === "number" && Number.isInteger(value);
const labelName = (label: number) =>
  label === 0 ? "human" : label === 1 ? "ai" : "suspected";
const percent = (value: number) => `${(value * 100).toFixed(1)}%`;
const compact = (value: number) => Number(value.toFixed(4)).toString();

function validate(input: JsonObject): string | null {
  if (
    typeof input.text !== "string" ||
    input.text.trim().length === 0 ||
    textLength(input.text) > maxTextLength
  )
    return "text must contain 1 to 20000 Unicode characters and cannot be blank";
  if (input.is_merge !== undefined && typeof input.is_merge !== "boolean")
    return "is_merge must be a boolean";
  return null;
}

function redact(value: string, secret: string): string {
  if (!secret) return value;
  const encoded = JSON.stringify(secret).slice(1, -1);
  return value.split(secret).join("***").split(encoded).join("***");
}

function unit(value: unknown): number | null {
  return finite(value) && value >= 0 && value <= 1 ? value : null;
}

function span(value: unknown): [number, number] | null {
  if (!Array.isArray(value) || value.length !== 2 || !value.every(finite))
    return null;
  return [value[0], value[1]];
}

function segment(value: unknown): JsonObject | null {
  if (
    !object(value) ||
    typeof value.text !== "string" ||
    !integer(value.label) ||
    value.label < 0 ||
    value.label > 2 ||
    !finite(value.conf) ||
    !integer(value.order)
  )
    return null;
  const position = span(value.position);
  if (!position) return null;
  return {
    text: value.text,
    label: labelName(value.label),
    confidence: value.conf,
    order: value.order,
    start: position[0],
    end: position[1],
  };
}

function tokens(value: unknown): number | null {
  return object(value) && integer(value.total_tokens) && value.total_tokens >= 0
    ? value.total_tokens
    : null;
}

function interpret(data: unknown): JsonObject {
  if (!object(data) || typeof data.status !== "string")
    return failure(
      "invalid_response",
      "Zhuque response does not match the expected result structure.",
    );
  if (data.status !== "success") {
    const message =
      typeof data.msg === "string" && data.msg.trim()
        ? data.msg
        : `Zhuque returned status ${data.status}`;
    return failure("detection_failed", message);
  }
  const ratios = object(data.labels_ratio) ? data.labels_ratio : null;
  const human = ratios ? unit(ratios["0"]) : null;
  const ai = ratios ? unit(ratios["1"]) : null;
  const suspected = ratios ? unit(ratios["2"]) : null;
  const characters = tokens(data.usage);
  const makersTokens = tokens(data.makers_models_usage);
  const segments = Array.isArray(data.segment_labels)
    ? data.segment_labels.map(segment)
    : null;
  if (
    human == null ||
    ai == null ||
    suspected == null ||
    !finite(data.softmax_confidence) ||
    !finite(data.ratio_confidence) ||
    segments == null ||
    segments.some((item) => item == null) ||
    characters == null ||
    makersTokens == null
  )
    return failure(
      "invalid_response",
      "Zhuque response does not match the expected result structure.",
    );
  const ordered = segments
    .filter((item): item is JsonObject => item != null)
    .sort((a, b) => Number(a.order) - Number(b.order));
  return {
    ok: true,
    summary: `人工 ${percent(human)}，AI ${percent(ai)}，疑似 AI ${percent(suspected)}。整体置信度 ${compact(data.softmax_confidence)}，疑似风险占比 ${compact(data.ratio_confidence)}。`,
    human_ratio: human,
    ai_ratio: ai,
    suspected_ratio: suspected,
    softmax_confidence: data.softmax_confidence,
    ratio_confidence: data.ratio_confidence,
    segments: ordered,
    usage: { characters, makers_tokens: makersTokens },
  };
}

function utf8Size(value: string): number {
  let bytes = 0;
  for (const ch of value) {
    const code = ch.codePointAt(0)!;
    bytes += code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
    if (bytes > resultLimit) break;
  }
  return bytes;
}

async function classify(
  context: PluginServices,
  input: JsonObject,
  timeoutMs: number,
): Promise<{ apiKey: string; response?: HttpResponse; result: JsonObject }> {
  let apiKey = "";
  let response: HttpResponse | undefined;
  try {
    apiKey = (await context.secrets.get("apiKey"))?.trim() ?? "";
    if (!apiKey)
      return {
        apiKey,
        result: failure(
          "missing_api_key",
          "Configure the Zhuque plugin API Key before calling this tool.",
        ),
      };
    response = await context.http.fetch(endpoint, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(input),
      timeoutMs,
    });
    let data: unknown;
    try {
      data = JSON.parse(response.body);
    } catch {
      /* Raw body is retained in the diagnostic below. */
    }
    const diagnostic = () => ({
      url: endpoint,
      status: response!.status,
      body: redact(response!.body, apiKey).slice(0, 4096),
      body_truncated: response!.body.length > 4096,
    });
    if (response.status !== 200) {
      const message =
        object(data) && typeof data.msg === "string" && data.msg.trim()
          ? data.msg
          : `Zhuque returned HTTP ${response.status}`;
      const code =
        response.status === 401 || response.status === 403
          ? "unauthorized"
          : response.status === 429
            ? "rate_limited"
            : "http_error";
      context.log.error("Zhuque request failed", diagnostic());
      return {
        apiKey,
        response,
        result: {
          ...failure(code, redact(message, apiKey)),
          status_code: response.status,
          diagnostic: diagnostic(),
        },
      };
    }
    const result = interpret(data);
    if (result.ok !== true) {
      context.log.error("Invalid Zhuque response", diagnostic());
      return {
        apiKey,
        response,
        result: { ...result, diagnostic: diagnostic() },
      };
    }
    if (utf8Size(JSON.stringify(result)) > resultLimit)
      return {
        apiKey,
        response,
        result: failure(
          "result_too_large",
          "Zhuque result exceeds the 256 KiB tool result limit. Detect a shorter passage.",
        ),
      };
    return { apiKey, response, result };
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
      url: endpoint,
      error: message,
      ...(response ? { status: response.status } : {}),
    };
    context.log.error("Zhuque request failed", diagnostic);
    return {
      apiKey,
      response,
      result: { ...failure(code, message), diagnostic },
    };
  }
}

/** Classifies a short sample; the settings page may pass an unsaved key. */
async function verifyApiKey(context: ActionContext): Promise<ActionResult> {
  const { result } = await classify(
    context,
    { text: verifyText, is_merge: true },
    15000,
  );
  if (result.ok === true) return { ok: true };
  return {
    ok: false,
    code:
      typeof result.error_code === "string"
        ? result.error_code
        : "request_failed",
    message:
      typeof result.error === "string" ? result.error : "Verification failed",
  };
}

export function apply(setup: PluginSetup): void {
  setup.settings.registerAction("verifyApiKey", verifyApiKey);
  setup.tools.register({
    ...definitions.ZhuqueDetect,
    display: {
      title: { "zh-CN": "朱雀检测", en: "Zhuque detection" },
      result: "text",
      resultPath: "summary",
    },
    handler: async (input, context) => {
      const invalid = validate(input);
      if (invalid) return failure("invalid_argument", invalid);
      const { result } = await classify(
        context,
        { text: input.text, is_merge: input.is_merge ?? true },
        45000,
      );
      return result;
    },
  });
}
