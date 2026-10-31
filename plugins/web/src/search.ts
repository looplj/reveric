import { parse } from "node-html-parser";
import type { JsonObject, ToolContext } from "../../sdk/index";
import {
  blocked,
  htmlAccept,
  language,
  logFailure,
  normalize,
  pageFailure,
  requestFailure,
  validUrl,
  stringArgument,
} from "./page";
export async function webSearch(
  context: ToolContext,
  input: JsonObject,
): Promise<JsonObject> {
  const query = stringArgument(input.query);
  if (!query)
    return {
      ok: false,
      error: "Query cannot be empty",
      error_code: "invalid_argument",
    };
  const raw = input.limit;
  const number =
    raw == null
      ? 5
      : typeof raw === "number" || typeof raw === "string"
        ? Number(raw)
        : NaN;
  if (!Number.isFinite(number) || (typeof raw === "string" && !raw.trim()))
    return {
      ok: false,
      error: "limit must be a number",
      error_code: "invalid_argument",
    };
  const limit = Math.max(1, Math.min(10, Math.trunc(number)));
  const url =
    "https://www.baidu.com/s?wd=" +
    encodeURIComponent(query).replace(/%20/g, "+");
  let requestUrl = url,
    stage = "fetch";
  try {
    const headers = { Accept: htmlAccept, "Accept-Language": language };
    let response = await context.http.fetch(requestUrl, { headers });
    let root: ReturnType<typeof parse> | undefined;
    if (
      response.status >= 200 &&
      response.status < 300 &&
      /^https:\/\/www\.baidu\.com\/s(?:[?#]|$)/i.test(response.url)
    ) {
      root = parse(response.body);
      // This intermediate page switches protocol while retaining the search query.
      // Its noscript meta refresh points to the homepage and must not be followed.
      const protocolRedirect =
        /^(?:window\.)?location\s*\.\s*replace\s*\(\s*(?:window\.)?location\s*\.\s*href\s*\.\s*replace\s*\(\s*(["'])https:\/\/\1\s*,\s*(["'])http:\/\/\2\s*\)\s*\)\s*;?\s*$/;
      if (
        !root.querySelector(".result, .c-container") &&
        !blocked(response.body) &&
        root
          .querySelectorAll("script")
          .some((script) => protocolRedirect.test(script.textContent.trim()))
      ) {
        requestUrl = response.url.replace(/^https:/i, "http:");
        stage = "redirect";
        response = await context.http.fetch(requestUrl, { headers });
        root = undefined;
      }
    }
    if (response.status < 200 || response.status >= 300) {
      const diagnostic = logFailure(context, "WebSearch", requestUrl, response);
      return {
        ok: false,
        diagnostic,
        status_code: response.status,
        failure_kind: "http",
        failure_stage: stage,
        error: "Web search is temporarily unavailable. Please try again later.",
        error_code: "unavailable",
      };
    }
    stage = "parse";
    if (blocked(response.body))
      return pageFailure(context, "WebSearch", requestUrl, response, "blocked");
    root ??= parse(response.body);
    const results: JsonObject[] = [];
    for (const block of root.querySelectorAll(".result, .c-container")) {
      if (
        /ec_result|ec-tuiguang|data-tuiguang|unified_ad|\/cpro\/|cmatch|<(?:span|i|em|b)\b[^>]*>\s*(?:广告|推广|商业推广)\s*<\/(?:span|i|em|b)>/i.test(
          block.outerHTML,
        )
      )
        continue;
      block.querySelectorAll("script,style").forEach((node) => node.remove());
      let data: Record<string, unknown> = {};
      try {
        const parsed: unknown = JSON.parse(
          block.getAttribute("data-tools") ?? "{}",
        );
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed))
          data = parsed as Record<string, unknown>;
      } catch {
        /* Malformed optional metadata falls back to the result anchor. */
      }
      const anchor = block.querySelector("h3 a");
      const title = normalize(
        parse(
          typeof data.title === "string" && data.title.trim()
            ? data.title
            : (anchor?.innerHTML ?? ""),
        ).textContent,
      );
      const target = normalize(
        typeof data.url === "string" && data.url.trim()
          ? data.url
          : (anchor?.getAttribute("href") ?? ""),
      );
      const abstract = block.querySelector(".c-abstract, .content-right_8Zs40");
      const snippet = normalize(
        abstract?.textContent ?? block.textContent.replace(title, ""),
      );
      if (title && validUrl(target))
        results.push({ title, url: target, ...(snippet ? { snippet } : {}) });
      if (results.length >= limit) break;
    }
    const noResults = root
      .querySelectorAll(".nors")
      .some((node) => /抱歉[，,]\s*没有找到与/.test(node.textContent));
    if (!results.length && !noResults)
      return pageFailure(
        context,
        "WebSearch",
        requestUrl,
        response,
        "invalid_response",
      );
    return { ok: true, query, engine: "baidu", results };
  } catch (error) {
    return requestFailure(context, "WebSearch", requestUrl, error, stage);
  }
}
