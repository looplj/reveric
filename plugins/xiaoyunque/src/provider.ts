import { PluginError } from "reveric-plugin-sdk";
import type {
  ProviderContext,
  ProviderHandlers,
  ProviderModel,
  VideoModelCapabilities,
  JsonObject,
} from "reveric-plugin-sdk";

const base = "https://xyq.jianying.com/api/biz/v1";
const shortModels = [
  "seedance2.0_fast_vision",
  "seedance2.0_vision",
  "Seedance_2.0_mini",
  "Seedance_2.5",
  "Seedance_2.5_flash",
  "MiniMax-H3",
  "MiniMax-H3-Max",
  "wan3.0",
  "happyhorse-1.1",
  "Seedance_2.0_mini_lite",
];
const marketingModels = [
  "seedance2.0_fast_vision",
  "seedance2.0_vision",
  "Seedance_2.0_mini",
  "Seedance_2.0_mini_lite",
];
const ratios = ["16:9", "9:16", "4:3", "3:4", "1:1"];
// Match the duration/count definitions in lib/shared/models/video/catalog.dart.
// Mini lite is the non-VIP mini tier; use the mini family baseline.
const durationRange = (min: number, max: number) =>
  Array.from({ length: max - min + 1 }, (_, i) => min + i);
const seedance20 = {
  durations: durationRange(4, 15),
  maxReferences: 15,
  references: {
    image: { maxCount: 9 },
    video: { maxCount: 3 },
    audio: { maxCount: 3 },
  },
};
const modelLimits: Record<
  string,
  Pick<VideoModelCapabilities, "durations" | "maxReferences" | "references"> &
    Pick<Partial<VideoModelCapabilities>, "maxPromptCharacters">
> = {
  "seedance2.0_fast_vision": seedance20,
  "seedance2.0_vision": seedance20,
  "Seedance_2.0_mini": seedance20,
  "Seedance_2.0_mini_lite": seedance20,
  "Seedance_2.5": {
    durations: durationRange(4, 30),
    maxReferences: 50,
    references: {
      image: { maxCount: 30 },
      video: { maxCount: 10 },
      audio: { maxCount: 10 },
    },
  },
  // Xiaoyunque web_unified_agent model configuration (xyq_models.json).
  // The form permits 4–180 s; max_output_duration caps a single output at 30 s.
  "Seedance_2.5_flash": {
    durations: durationRange(4, 30),
    maxReferences: 50,
    maxPromptCharacters: 15000,
    references: {
      image: {
        maxCount: 10,
        maxSizeMb: 30,
        mimeTypes: [
          "image/jpeg",
          "image/png",
          "image/webp",
          "image/bmp",
          "image/gif",
        ],
        minDimension: 300,
        maxDimension: 6000,
        minRatio: 0.4,
        maxRatio: 2.5,
      },
      video: {
        maxCount: 5,
        minDurationMs: 2000,
        maxDurationMs: 30200,
        maxTotalDurationMs: 30200,
        minDimension: 300,
        maxDimension: 6000,
        minRatio: 0.4,
        maxRatio: 2.5,
        minFrameRate: 24,
        maxFrameRate: 60,
        minPixels: 409600,
        maxPixels: 8295044,
      },
      audio: {
        maxCount: 5,
        minDurationMs: 2000,
        maxDurationMs: 30000,
        maxTotalDurationMs: 30200,
      },
    },
  },
  "MiniMax-H3": {
    durations: durationRange(4, 15),
    maxReferences: 12,
    references: {
      image: { maxCount: 9 },
      video: { maxCount: 3 },
      audio: { maxCount: 3 },
    },
  },
  "MiniMax-H3-Max": {
    durations: durationRange(5, 15),
    maxReferences: 2,
    references: { image: { maxCount: 2 } },
  },
  "wan3.0": {
    durations: durationRange(2, 30),
    maxReferences: 20,
    references: {
      image: { maxCount: 10 },
      video: { maxCount: 5 },
      audio: { maxCount: 5 },
    },
  },
  "happyhorse-1.1": {
    durations: durationRange(3, 15),
    maxReferences: 2,
    references: { image: { maxCount: 2 } },
  },
};
const object = (v: unknown): v is JsonObject =>
  !!v && typeof v === "object" && !Array.isArray(v);
function required(v: unknown, field: string): string {
  if (typeof v !== "string" || !v.trim())
    throw new PluginError("invalid_response", `Missing ${field}`);
  return v;
}
async function headers(ctx: ProviderContext) {
  const key = (await ctx.secrets.get("accessKey"))?.trim();
  if (!key)
    throw new PluginError(
      "configuration_required",
      "请配置小云雀 Access Key / Configure Xiaoyunque Access Key",
    );
  return { Authorization: `Bearer ${key}`, Accept: "application/json" };
}
function decode(status: number, body: unknown): JsonObject {
  let value = body;
  if (typeof body === "string") {
    try {
      value = JSON.parse(body);
    } catch {
      throw new PluginError(
        "invalid_response",
        `Xiaoyunque HTTP ${status}: invalid JSON`,
      );
    }
  }
  if (!object(value))
    throw new PluginError("invalid_response", "Invalid Xiaoyunque response");
  if (status < 200 || status >= 300 || (value.ret !== "0" && value.ret !== 0)) {
    throw new PluginError(
      "provider_error",
      typeof value.errmsg === "string" && value.errmsg.trim()
        ? value.errmsg
        : `Xiaoyunque HTTP ${status}, ret=${String(value.ret)}`,
    );
  }
  if (!object(value.data))
    throw new PluginError("invalid_response", "Missing Xiaoyunque data");
  return value.data;
}

async function creditBalance(ctx: ProviderContext): Promise<string> {
  const result = await ctx.http.fetch(`${base}/skill/get_credit_balance`, {
    method: "POST",
    headers: { ...(await headers(ctx)), "Content-Type": "application/json" },
    body: "{}",
    timeoutMs: 15000,
  });
  const data = decode(result.status, result.body);
  const balance = required(data.total_remain_amount, "total_remain_amount");
  if (!/^\d+$/.test(balance))
    throw new PluginError("invalid_response", "Invalid credit balance");
  return balance;
}

// Both entry points bundle this implementation into their own standalone package.
export function createXiaoyunqueProvider(
  kind: "short" | "marketing",
): ProviderHandlers {
  const marketing = kind === "marketing";
  const provider: ProviderHandlers = {
    listModels() {
      return (marketing ? marketingModels : shortModels).map(
        (model): ProviderModel => ({
          kind: "video",
          id: model,
          name: model,
          // Model limits follow the catalog; the guide supplies channel options.
          capabilities: {
            ratios,
            resolutions:
              model === "seedance2.0_vision"
                ? ["480p", "720p", "1080p"]
                : ["480p", "720p"],
            ...modelLimits[model],
            // Marketing duration describes the composed video, not a single shot.
            durations: marketing
              ? [10, 15, 30, 60]
              : modelLimits[model].durations,
            modes: marketing
              ? ["text", "reference"]
              : ["text", "first_frame", "first_last_frame", "reference"],
            frameRoles: marketing ? [] : ["first_frame", "last_frame"],
            maxMiddleFrames: 0,
            supportsAudioOnlyReference: false,
            supportsAdaptiveTextRatio: false,
            supportsLastFrameOnly: false,
            framesRequireAdaptiveRatio: false,
            supportsCertifiedAssets: false,
            draft: null,
          },
        }),
      );
    },
    async checkConnection(ctx) {
      await creditBalance(ctx);
      return { accountLabel: "小云雀 / Xiaoyunque" };
    },
    actions: {
      async queryCredits(ctx) {
        const balance = await creditBalance(ctx);
        return {
          ok: true,
          text: {
            "zh-CN": `剩余积分：${balance}`,
            en: `Credits remaining: ${balance}`,
          },
        };
      },
    },
    async uploadReference({ file }, ctx) {
      const result = await ctx.files.upload(file.handle, {
        kind: "multipart",
        url: `${base}/skill/upload_file`,
        headers: await headers(ctx),
        fields: {},
        fileField: "file",
        timeoutMs: 300000,
      });
      return {
        ref: required(
          decode(result.status, result.body).pippit_asset_id,
          "pippit_asset_id",
        ),
      };
    },
    video: {
      async submit(input, ctx) {
        const r = input.request;
        const model = r.modelId;
        const models = await provider.listModels(ctx);
        const definition = models.find((m) => m.id === r.modelId);
        if (
          !definition ||
          definition.kind !== "video" ||
          !r.prompt.trim() ||
          !definition.capabilities.ratios.includes(r.ratio) ||
          !definition.capabilities.resolutions.includes(r.resolution) ||
          !definition.capabilities.durations.includes(r.durationSeconds) ||
          !definition.capabilities.modes.includes(r.mode) ||
          r.draft ||
          input.draftOf
        ) {
          throw new PluginError(
            "invalid_request",
            "Unsupported Xiaoyunque video parameters",
          );
        }
        const refs = [...input.references];
        const frames =
          r.mode === "first_frame" || r.mode === "first_last_frame";
        if (
          (r.mode === "text" && refs.length) ||
          (r.mode === "reference" && !refs.length) ||
          (!frames && refs.length > definition.capabilities.maxReferences) ||
          (frames &&
            (refs.length !== (r.mode === "first_frame" ? 1 : 2) ||
              refs.filter((x) => x.role === "first_frame").length !== 1 ||
              (r.mode === "first_last_frame" &&
                refs.filter((x) => x.role === "last_frame").length !== 1)))
        )
          throw new PluginError(
            "invalid_request",
            "Invalid Xiaoyunque reference roles",
          );
        if (frames)
          refs.sort(
            (a, b) =>
              (a.role === "first_frame" ? 0 : 1) -
              (b.role === "first_frame" ? 0 : 1),
          );
        const groups: Record<string, JsonObject[]> = {
          images: [],
          videos: [],
          audios: [],
        };
        const ids = refs.map((ref) => {
          if (ref.source.kind !== "uploaded")
            throw new PluginError(
              "invalid_request",
              "Xiaoyunque references must be uploaded first",
            );
          const kind = ref.mimeType.split("/")[0];
          if (
            !["image", "video", "audio"].includes(kind) ||
            (frames && kind !== "image") ||
            (!frames && ref.role !== `reference_${kind}`)
          )
            throw new PluginError(
              "invalid_request",
              "Unsupported reference type or role",
            );
          const id = required(ref.source.ref, "reference asset ID");
          groups[`${kind}s`].push({ pippit_asset_id: id });
          return id;
        });
        if (
          (!frames &&
            (["image", "video", "audio"] as const).some(
              (kind) =>
                groups[`${kind}s`].length >
                (definition.capabilities.references[kind]?.maxCount ?? 0),
            )) ||
          (refs.length && !groups.images.length && !groups.videos.length)
        )
          throw new PluginError(
            "invalid_request",
            "Unsupported reference counts",
          );
        const body: JsonObject = { message: r.prompt, asset_ids: ids };
        if (marketing) {
          body.general_agent_settings = {
            ratio: ratios.indexOf(r.ratio) + 2,
            video_model: model,
            duration_start: r.durationSeconds,
            duration_end: r.durationSeconds,
            video_resolution: r.resolution,
            show_subtitle: (await ctx.settings.get("showSubtitle")) ?? true,
          };
        } else {
          body.agent_name = "pippit_video_part_agent";
          body.video_part_tool_param = {
            prompt: r.prompt,
            model,
            ratio: r.ratio,
            duration_sec: r.durationSeconds,
            resolution: r.resolution,
            ...groups,
            ...(frames ? { generate_type: 1 } : {}),
          };
        }
        const result = await ctx.video.request(
          `${base}/${marketing ? "agent/submit_marketing_run" : "skill/submit_run"}`,
          {
            method: "POST",
            headers: await headers(ctx),
            body: { kind: "json", value: body },
            response: { kind: "json" },
            timeoutMs: 300000,
          },
        );
        const data = decode(result.status, result.body);
        if (!object(data.run))
          throw new PluginError("invalid_response", "Missing run receipt");
        return {
          status: "submitted",
          remoteTaskId: required(data.run.run_id, "run_id"),
          state: { threadId: required(data.run.thread_id, "thread_id") },
        };
      },
      async query(input, ctx) {
        const thread = required(input.state?.threadId, "persisted thread_id");
        const result = await ctx.video.request(
          `${base}/agent/query_generate_video_result`,
          {
            method: "POST",
            headers: await headers(ctx),
            body: {
              kind: "json",
              value: { thread_id: thread, run_id: input.remoteTaskId },
            },
            response: { kind: "json" },
            timeoutMs: 300000,
          },
        );
        const data = decode(result.status, result.body);
        if (data.run_id !== input.remoteTaskId || data.thread_id !== thread)
          throw new PluginError("invalid_response", "Task identity mismatch");
        switch (String(data.run_state)) {
          case "1":
            return { status: "queued" };
          case "2":
            return { status: "running" };
          case "3": {
            const urls = data.video_urls;
            if (
              !Array.isArray(urls) ||
              urls.length === 0 ||
              typeof urls[0] !== "string" ||
              !/^https?:\/\/[^\s]+$/i.test(urls[0])
            )
              return {
                status: "unknown",
                reason:
                  "小云雀未返回有效的首个视频，请在小云雀查看任务结果 / No valid first video output; inspect the task in Xiaoyunque",
              };
            if (urls.length > 1) {
              ctx.log.info(
                "Xiaoyunque returned multiple videos; using only the first",
                {
                  remoteTaskId: input.remoteTaskId,
                  threadId: thread,
                  outputCount: urls.length,
                  selectedIndex: 0,
                },
              );
            }
            return {
              status: "succeeded",
              outputs: [{ kind: "url", url: urls[0] }],
            };
          }
          case "4":
            return {
              status: "failed",
              error: {
                code: object(data.fail_reason)
                  ? String(data.fail_reason.code ?? "generation_failed")
                  : "generation_failed",
                message:
                  object(data.fail_reason) &&
                  typeof data.fail_reason.message === "string"
                    ? data.fail_reason.message
                    : "小云雀视频生成失败 / Xiaoyunque generation failed",
              },
            };
          case "5":
            return { status: "cancelled" };
          default:
            return {
              status: "unknown",
              reason: `Unknown Xiaoyunque run_state: ${String(data.run_state)}`,
            };
        }
      },
    },
  };
  return provider;
}
