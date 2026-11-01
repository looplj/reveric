import { parse } from "node-html-parser";
import { NodeHtmlMarkdown } from "node-html-markdown";
import { getMarkdownForHtmlNodes } from "node-html-markdown/dist/visitor";
import { nodeHtmlParserConfig } from "node-html-markdown/dist/utilities";
import { buildAbsoluteURL } from "url-toolkit";
import type { JsonObject, ToolContext } from "reveric-plugin-sdk";
import {
  blocked,
  htmlAccept,
  language,
  isHtml,
  logFailure,
  normalize,
  pageFailure,
  requestFailure,
  validUrl,
  stringArgument,
} from "./page";
const isBaiduRedirect = (url: string): boolean =>
  /^https?:\/\/(?:[^/]+\.)?baidu\.com(?::\d+)?\/(?:link(?:[?#]|$)|baidu\.php(?:[?#]|$)|[^?#]*\/link(?:[?#]|$))/i.test(
    url,
  );
function redirectTarget(url: string, body: string): string | null {
  const candidates = [
    /(?:window\.)?location\.(?:replace|assign)\(\s*(["'])(.*?)\1\s*\)/is.exec(
      body,
    )?.[2],
    /(?:window\.)?location\.href\s*=\s*(["'])(.*?)\1/is.exec(body)?.[2],
    parse(body)
      .querySelectorAll("meta")
      .find(
        (node) => node.getAttribute("http-equiv")?.toLowerCase() === "refresh",
      )
      ?.getAttribute("content")
      ?.match(/url\s*=\s*['"]?([^'">]+)/i)?.[1],
  ];
  for (const candidate of candidates) {
    if (!candidate) continue;
    const decoded = parse(
      candidate
        .replace(/\\u([0-9a-f]{4})/gi, (_, hex: string) =>
          String.fromCharCode(parseInt(hex, 16)),
        )
        .replace(/\\\//g, "/")
        .replace(/\\"/g, '"')
        .replace(/\\'/g, "'")
        .replace(/\\\\/g, "\\"),
    ).textContent.trim();
    if (validUrl(decoded)) return decoded;
    const origin = /^(https?:\/\/[^/]+)/i.exec(url)?.[1];
    if (origin && decoded.startsWith("/"))
      return decoded.startsWith("//")
        ? url.split(":")[0] + ":" + decoded
        : origin + decoded;
    if (origin && decoded && !/^[a-z][a-z0-9+.-]*:/i.test(decoded))
      return url.split(/[?#]/)[0].replace(/[^/]*$/, "") + decoded;
  }
  return null;
}
export async function webFetch(
  context: ToolContext,
  input: JsonObject,
): Promise<JsonObject> {
  const raw = stringArgument(input.url);
  if (!raw)
    return {
      ok: false,
      error: "URL cannot be empty",
      error_code: "invalid_argument",
    };
  if (!validUrl(raw))
    return {
      ok: false,
      error: "URL must start with http:// or https://",
      error_code: "invalid_argument",
    };
  let stage = isBaiduRedirect(raw) ? "redirect" : "fetch",
    target = raw;
  try {
    if (stage === "redirect") {
      const response = await context.http.fetch(raw, {
        headers: { Accept: htmlAccept, "Accept-Language": language },
      });
      if (response.status < 200 || response.status >= 300) {
        const diagnostic = logFailure(context, "WebFetch", raw, response);
        return {
          ok: false,
          diagnostic,
          error: `Baidu redirect URL is unavailable. HTTP ${response.status}.`,
          error_code: "unavailable",
          url: raw,
          status_code: response.status,
          failure_stage: "redirect",
          failure_kind: "http",
        };
      }
      if (blocked(response.body))
        return pageFailure(
          context,
          "WebFetch",
          raw,
          response,
          "blocked",
          "redirect",
        );
      const resolved =
        response.url !== raw &&
        !isBaiduRedirect(response.url) &&
        validUrl(response.url)
          ? response.url
          : redirectTarget(raw, response.body);
      if (!resolved) {
        const diagnostic = logFailure(
          context,
          "WebFetch",
          raw,
          response,
          undefined,
          "redirect_resolution",
        );
        return {
          ok: false,
          error: "Unable to resolve Baidu redirect URL.",
          diagnostic,
          error_code: "unavailable",
          url: raw,
          failure_stage: "redirect",
          failure_kind: "redirect_resolution",
        };
      }
      target = resolved;
    }
    stage = "fetch";
    const response = await context.http.fetch(target, {
      headers: {
        Accept:
          "text/markdown;q=1.0, text/x-markdown;q=0.9, text/plain;q=0.8, text/html;q=0.7, */*;q=0.1",
        "Accept-Language": language,
      },
    });
    if (response.status < 200 || response.status >= 300) {
      const diagnostic = logFailure(context, "WebFetch", target, response);
      return {
        ok: false,
        diagnostic,
        error: "Web fetch is temporarily unavailable. Please try again later.",
        error_code: "unavailable",
        status_code: response.status,
        failure_kind: "http",
        failure_stage: stage,
      };
    }
    stage = "parse";
    const contentType = response.headers["content-type"] ?? "",
      html = isHtml(response.body, contentType),
      root = html ? parse(response.body, nodeHtmlParserConfig) : null,
      title = normalize(root?.querySelector("title")?.textContent ?? "");
    if (html && blocked(response.body, title))
      return pageFailure(
        context,
        "WebFetch",
        response.url,
        response,
        "blocked",
      );
    if (root) {
      let base = response.url;
      const declaredBase = root
        .querySelector("base[href]")
        ?.getAttribute("href");
      if (declaredBase) {
        try {
          base = buildAbsoluteURL(base, declaredBase);
        } catch {
          // An invalid document base leaves the response URL as the base.
        }
      }
      for (const image of root.querySelectorAll("img[src]")) {
        const src = image.getAttribute("src")?.trim();
        if (!src) continue;
        try {
          image.setAttribute("src", buildAbsoluteURL(base, src));
        } catch {
          // A malformed image URL must not discard the readable page text.
        }
      }
    }
    // Reuse the parser/visitor exported by the pinned Markdown package; the
    // string API would serialize this tree and retain a second full DOM.
    const content = (
      root
        ? getMarkdownForHtmlNodes(
            new NodeHtmlMarkdown({
              preferNativeParser: false,
              ignore: ["script", "style", "meta", "link", "noscript"],
            }),
            root,
          )
        : response.body
    ).trim();
    root
      ?.querySelectorAll("head,title,noscript,script,style")
      .forEach((node) => node.remove());
    const bodyText = root ? normalize(root.textContent) : content;
    if (!content || !bodyText || (html && bodyText === title))
      return pageFailure(
        context,
        "WebFetch",
        response.url,
        response,
        "empty_content",
      );
    const truncated = content.length > 10240,
      visible = content.slice(0, 10240);
    return {
      ok: true,
      url: response.url,
      ...(target !== raw ? { resolved_url: target } : {}),
      ...(title ? { title } : {}),
      content: visible,
      format: "markdown",
      truncated,
      returned_chars: visible.length,
      total_chars: content.length,
      ...(contentType ? { content_type: contentType } : {}),
      ...(truncated
        ? {
            warning:
              "Content was truncated to 10240 characters. Fetch a more specific URL if more detail is needed.",
          }
        : {}),
    };
  } catch (error) {
    return requestFailure(context, "WebFetch", raw, error, stage);
  }
}
