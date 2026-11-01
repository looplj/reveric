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
