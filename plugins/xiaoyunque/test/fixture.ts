import type {
  ProviderVideoContext,
  ProviderUploadContext,
  ProviderVideoInput,
  JsonObject,
} from "reveric-plugin-sdk";

export function fixture(
  data: JsonObject = { run: { run_id: "run", thread_id: "thread" } },
) {
  const calls: any[] = [];
  const logs: Array<{ message: string; data?: JsonObject }> = [];
  let response: any = { status: 200, body: { ret: "0", data }, headers: {} };
  const request = async (...args: any[]) => {
    calls.push(args);
    return response;
  };
  const ctx = {
    plugin: { id: "reveric.xiaoyunque", version: "1.0.0" },
    provider: { id: "instance" },
    callId: "call",
    taskId: "task",
    secrets: { get: async () => "key" },
    settings: { get: async () => false },
    storage: {} as any,
    log: {
      info(message: string, data?: JsonObject) {
        logs.push({ message, data });
      },
      warn() {},
      error() {},
    },
    video: { request },
    http: {
      fetch: async (...args: any[]) => {
        calls.push(args);
        return { ...response, body: JSON.stringify(response.body) };
      },
    },
    files: {
      upload: async (...args: any[]) => {
        calls.push(args);
        return { ...response, body: JSON.stringify(response.body) };
      },
    },
  } as unknown as ProviderVideoContext & ProviderUploadContext;
  const input: ProviderVideoInput = {
    request: {
      modelId: "Seedance_2.0_mini",
      prompt: "测试短片",
      mode: "text",
      ratio: "16:9",
      resolution: "480p",
      durationSeconds: 10,
      defaults: {},
      referenceSlots: [],
    },
    references: [],
  };
  return {
    ctx,
    calls,
    logs,
    input,
    respond: (value: any) => {
      response = value;
    },
  };
}
