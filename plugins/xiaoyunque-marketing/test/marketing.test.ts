import { test } from "node:test";
import assert from "node:assert/strict";
import type { PluginSetup } from "reveric-plugin-sdk";
import { provider, apply } from "../src/index";
import { fixture } from "../../xiaoyunque/test/fixture";

test("marketing maps ratio enums, exact duration and instance subtitle setting", async () => {
  const f = fixture();
  await provider.video!.submit(f.input, f.ctx);
  assert.match(f.calls[0][0], /agent\/submit_marketing_run$/);
  assert.equal(f.calls[0][1].timeoutMs, 300000);
  assert.deepEqual(f.calls[0][1].body.value.general_agent_settings, {
    ratio: 2,
    video_model: "Seedance_2.0_mini",
    duration_start: 10,
    duration_end: 10,
    video_resolution: "480p",
    show_subtitle: false,
  });
});

test("registers four marketing models with plain model IDs", async () => {
  let registered;
  apply({
    provider: {
      register(p) {
        registered = p;
      },
    },
  } as PluginSetup);
  assert.equal(registered, provider);
  const models = await provider.listModels(fixture().ctx);
  assert.deepEqual(
    models.map((m) => m.id),
    [
      "seedance2.0_fast_vision",
      "seedance2.0_vision",
      "Seedance_2.0_mini",
      "Seedance_2.0_mini_lite",
    ],
  );
  for (const model of models) {
    assert.equal(model.name, model.id);
    assert.ok(model.kind === "video");
    assert.deepEqual(model.capabilities.modes, ["text", "reference"]);
  }
});
test("marketing rejects short-film-only models and frame modes", async () => {
  const f = fixture();
  f.input.request.modelId = "Seedance_2.5";
  await assert.rejects(provider.video!.submit(f.input, f.ctx), /parameters/);
  f.input.request.modelId = "Seedance_2.0_mini";
  f.input.request.mode = "first_frame";
  await assert.rejects(provider.video!.submit(f.input, f.ctx), /parameters/);
  assert.equal(f.calls.length, 0);
});
test("marketing applies subtitles and 60-second preference", async () => {
  const f = fixture();
  f.ctx.settings.get = async () => true;
  f.input.request.durationSeconds = 60;
  f.input.request.ratio = "9:16";
  await provider.video!.submit(f.input, f.ctx);
  const body = f.calls[0][1].body.value;
  assert.equal(body.general_agent_settings.show_subtitle, true);
  assert.equal(body.general_agent_settings.duration_start, 60);
  assert.equal(body.general_agent_settings.duration_end, 60);
  assert.equal(body.general_agent_settings.ratio, 3);
  assert.equal(body.video_part_tool_param, undefined);
});
test("marketing exposes credit queries and takes the first video with a log", async () => {
  const credits = fixture({ total_remain_amount: "100" });
  assert.deepEqual(await provider.actions!.queryCredits(credits.ctx), {
    ok: true,
    text: { "zh-CN": "剩余积分：100", en: "Credits remaining: 100" },
  });
  const f = fixture({
    run_id: "run",
    thread_id: "thread",
    run_state: 3,
    video_urls: [
      "https://example.com/first.mp4",
      "https://example.com/second.mp4",
    ],
  });
  assert.deepEqual(
    await provider.video!.query(
      { remoteTaskId: "run", state: { threadId: "thread" } },
      f.ctx,
    ),
    {
      status: "succeeded",
      outputs: [{ kind: "url", url: "https://example.com/first.mp4" }],
    },
  );
  assert.equal(f.logs[0].data?.outputCount, 2);
});
