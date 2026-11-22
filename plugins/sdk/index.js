// Runtime part of the SDK; types are declared in index.d.ts.
export class PluginError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "PluginError";
    this.code = code;
  }
}
export function isHostError(error, code) {
  return (
    error instanceof Error &&
    error.name === "PluginHostError" &&
    (code === undefined || error.code === code)
  );
}

const PAGE_BADGE_STORAGE_PREFIX = "__system_internal_page_badge:";

export async function setPageBadge(storage, pageId, badge) {
  if (typeof pageId !== "string" || !pageId.trim()) {
    throw new PluginError("invalid_argument", "pageId is required");
  }
  const key = PAGE_BADGE_STORAGE_PREFIX + pageId.trim();
  if (!badge) {
    await storage.remove(key);
    return;
  }
  const payload = {};
  if (
    typeof badge.count === "number" &&
    Number.isInteger(badge.count) &&
    badge.count > 0
  ) {
    payload.count = badge.count;
  }
  if (badge.dot === true) {
    payload.dot = true;
  }
  if (
    badge.tone === "accent" ||
    badge.tone === "warning" ||
    badge.tone === "danger"
  ) {
    payload.tone = badge.tone;
  }
  if (!payload.count && !payload.dot) {
    await storage.remove(key);
    return;
  }
  await storage.set(key, payload);
}
