import { parse } from "node-html-parser";
import type {
  PluginServices,
  HttpResponse,
  JsonObject,
  Json,
} from "../../sdk/index";
export const language = "zh-CN,zh;q=0.9,en;q=0.8";
export const htmlAccept =
  "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8";
export const normalize = (text: string): string =>
  text.replace(/\s+/g, " ").trim();
export const titleOf = (body: string): string =>
  normalize(parse(body).querySelector("title")?.textContent ?? "");
export function isHtml(body: string, contentType: string): boolean {
  const mime = contentType.split(";")[0].trim().toLowerCase();
  if (["text/html", "application/xhtml+xml"].includes(mime)) return true;
  if (mime && !["text/plain", "application/octet-stream"].includes(mime))
    return false;
  return /^\s*(?:<!--[\s\S]*?-->\s*)*(?:<!doctype\s+html\b|<html\b|<head\b|<body\b)/i.test(
    body,
  );
}
export function blocked(body: string): boolean {
  const title = titleOf(body).toLowerCase(),
    lower = body.toLowerCase();
  return (
    title === "百度安全验证" ||
    (title === "duckduckgo" &&
      lower.includes("unfortunately, bots use duckduckgo too.") &&
      lower.includes("confirm this search was made by a human")) ||
    (title === "豆瓣" &&
      /<form\b[^>]*\bid=["']sec["']/i.test(body) &&
      /<input\b[^>]*\bid=["']cha["']/i.test(body) &&
      /<input\b[^>]*\bid=["']sol["']/i.test(body) &&
      lower.includes("sha512"))
  );
}
export function logFailure(
  context: PluginServices,
  tool: string,
  url: string,
  response?: HttpResponse,
  error?: unknown,
  kind?: string,
): JsonObject {
  const diagnostic: JsonObject = { url };
  if (response) {
    diagnostic.status = response.status;
    diagnostic.body = response.body.slice(0, 400);
    diagnostic.body_truncated = response.body.length > 400;
  }
  if (error !== undefined) diagnostic.error = String(error);
  if (kind) diagnostic.failure_kind = kind;
  context.log.warn(`[${tool}] request failed`, diagnostic);
  return diagnostic;
}
export function pageFailure(
  context: PluginServices,
  tool: string,
  url: string,
  response: HttpResponse,
  kind: string,
  stage = "parse",
): JsonObject {
  const diagnostic = logFailure(context, tool, url, response, undefined, kind);
  return {
    ok: false,
    diagnostic,
    error_code: "unavailable",
    error:
      kind === "blocked"
        ? "The website returned an anti-bot verification page instead of the requested content. Use another source; avoid immediately retrying this website."
        : kind === "empty_content"
          ? "The page returned no readable body content. It may require JavaScript or browser verification. Try another source."
          : "The search response could not be recognized. This does not mean no matching pages exist. Try another source or retry later.",
    status_code: response.status,
    failure_kind: kind,
    failure_stage: stage,
  };
}
export function requestFailure(
  context: PluginServices,
  tool: string,
  url: string,
  error: unknown,
  stage: string,
): JsonObject {
  const code =
    typeof error === "object" && error !== null && "code" in error
      ? String(error.code)
      : "exception";
  const diagnostic = logFailure(context, tool, url, undefined, error, code);
  return {
    ok: false,
    diagnostic,
    error_code:
      code === "too_large"
        ? "resource_exhausted"
        : code === "invalid_url"
          ? "invalid_argument"
          : "unavailable",
    error:
      code === "too_large"
        ? "Fetched page is too large to read."
        : `Web ${tool === "WebFetch" ? "fetch" : "search"} failed. Please try again later.`,
    failure_kind: code,
    failure_stage: stage,
    failure_type: error instanceof Error ? error.name : "Error",
  };
}
export const validUrl = (value: string): boolean =>
  /^https?:\/\/[^/\s?#]+(?:[/?#]|$)/i.test(value);

// Preserve the existing tool boundary's scalar/list/map string coercion.
export function stringArgument(value: Json | undefined): string {
  function render(item: Json): string {
    if (Array.isArray(item)) return `[${item.map(render).join(", ")}]`;
    if (item !== null && typeof item === "object") {
      return `{${Object.entries(item)
        .map(([key, val]) => `${key}: ${render(val)}`)
        .join(", ")}}`;
    }
    return String(item);
  }
  return value == null ? "" : render(value);
}
