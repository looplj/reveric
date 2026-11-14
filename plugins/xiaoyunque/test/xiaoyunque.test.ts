import { test } from "node:test";
import assert from "node:assert/strict";
import { provider, apply } from "../src/index";
import type { ProviderVideoInput, PluginSetup } from "reveric-plugin-sdk";
import { fixture } from "./fixture";
import { provider as marketingProvider } from "../../xiaoyunque-marketing/src/index";

function imageReferences(count: number): ProviderVideoInput["references"] {
  return Array.from({ length: count }, (_, index) => ({
    assetId: `image-${index}`,
    role: "reference_image",
    mimeType: "image/png",
    fileSize: 1,
    mediaInfo: {},
    source: { kind: "uploaded", ref: `uploaded-${index}` },
  }));
}
for (const [kind, target] of [
  ["short", provider],
  ["marketing", marketingProvider],
] as const) {
  for (const count of [5, 9]) {
    test(`${kind} submits ${count} mini reference images without dropping any`, async () => {
      const f = fixture();
      f.input.request.mode = "reference";
      f.input.references = imageReferences(count);
      await target.video!.submit(f.input, f.ctx);
      assert.equal(f.calls.length, 1);
      assert.deepEqual(
        f.calls[0][1].body.value.asset_ids,
        f.input.references.map(
          (ref) => ref.source.kind === "uploaded" && ref.source.ref,
        ),
      );
      if (kind === "short") {
        assert.equal(
          f.calls[0][1].body.value.video_part_tool_param.images.length,
          count,
        );
      }
    });
  }
  test(`${kind} rejects 10 mini reference images before network`, async () => {
    const f = fixture();
    f.input.request.mode = "reference";
    f.input.references = imageReferences(10);
    await assert.rejects(target.video!.submit(f.input, f.ctx), /reference/i);
    assert.equal(f.calls.length, 0);
  });
}
for (const duration of [4, 15]) {
  test(`mini submits ${duration}-second short films`, async () => {
    const f = fixture();
    f.input.request.durationSeconds = duration;
    await provider.video!.submit(f.input, f.ctx);
    assert.equal(
      f.calls[0][1].body.value.video_part_tool_param.duration_sec,
      duration,
    );
  });
}
const queryInput = { remoteTaskId: "run", state: { threadId: "thread" } };
test("registers only short-film models", async () => {
  let registered;
  apply({
    provider: {
      register: (p: any) => {
        registered = p;
      },
    },
  } as PluginSetup);
  assert.equal(registered, provider);
  const models = await provider.listModels(fixture().ctx);
  assert.equal(models.length, 10);
  assert.equal(
    models.filter((m) => m.capabilities.resolutions.includes("1080p")).length,
    1,
  );
});
test("Flash submits its exact model ID with ten images and a 30-second duration", async () => {
  const f = fixture();
  f.input.request.modelId = "Seedance_2.5_flash";
  f.input.request.mode = "reference";
  f.input.request.resolution = "720p";
  f.input.request.durationSeconds = 30;
  f.input.references = imageReferences(10);
  const model = (await provider.listModels(f.ctx)).find(
    (m) => m.id === f.input.request.modelId,
  )!;
  assert.equal(model.kind, "video");
  assert.deepEqual(model.capabilities.resolutions, ["480p", "720p"]);
  await provider.video!.submit(f.input, f.ctx);
  const params = f.calls[0][1].body.value.video_part_tool_param;
  assert.equal(params.model, "Seedance_2.5_flash");
  assert.equal(params.duration_sec, 30);
  assert.equal(params.resolution, "720p");
  assert.equal(params.images.length, 10);
  f.input.references = imageReferences(11);
  await assert.rejects(provider.video!.submit(f.input, f.ctx), /reference/i);
  f.input.references = [];
  f.input.request.mode = "text";
  f.input.request.durationSeconds = 31;
  await assert.rejects(provider.video!.submit(f.input, f.ctx), /parameters/);
  f.input.request.durationSeconds = 30;
  f.input.request.resolution = "1080p";
  await assert.rejects(provider.video!.submit(f.input, f.ctx), /parameters/);
  assert.equal(f.calls.length, 1);
});
test("submits short film and persists both identifiers without credentials", async () => {
  const f = fixture();
  f.ctx.settings.get = async () => {
    throw new Error("Short-film provider must not read subtitle settings");
  };
  assert.deepEqual(await provider.video!.submit(f.input, f.ctx), {
    status: "submitted",
    remoteTaskId: "run",
    state: { threadId: "thread" },
  });
  assert.match(f.calls[0][0], /skill\/submit_run$/);
  assert.equal(f.calls[0][1].timeoutMs, 300000);
  const body = f.calls[0][1].body.value;
  assert.equal(body.message, body.video_part_tool_param.prompt);
  assert.equal(body.video_part_tool_param.model, "Seedance_2.0_mini");
  assert.equal(body.video_part_tool_param.generate_type, undefined);
});
test("frame references are ordered first then last regardless of input order", async () => {
  const f = fixture();
  f.input.request.mode = "first_last_frame";
  f.input.references = ["last_frame", "first_frame"].map((role) => ({
    assetId: role,
    role,
    mimeType: "image/png",
    fileSize: 1,
    mediaInfo: {},
    source: { kind: "uploaded", ref: role },
  })) as ProviderVideoInput["references"];
  await provider.video!.submit(f.input, f.ctx);
  assert.deepEqual(f.calls[0][1].body.value.asset_ids, [
    "first_frame",
    "last_frame",
  ]);
  assert.equal(f.calls[0][1].body.value.video_part_tool_param.generate_type, 1);
});
test("uploads through host file handle and returns remote asset identity", async () => {
  const f = fixture({ pippit_asset_id: "asset" });
  assert.deepEqual(
    await provider.uploadReference!(
      {
        file: {
          handle: "opaque",
          name: "x.png",
          mimeType: "image/png",
          size: 1,
          sha256: "hash",
        },
      },
      f.ctx,
    ),
    { ref: "asset" },
  );
  assert.equal(f.calls[0][0], "opaque");
  assert.equal(f.calls[0][1].fileField, "file");
  assert.equal(f.calls[0][1].headers["Content-Type"], undefined);
});
test("connection checks zero balance as valid without a generation request", async () => {
  const f = fixture({ total_remain_amount: "0" });
  assert.equal(
    (await provider.checkConnection!(f.ctx)).accountLabel,
    "小云雀 / Xiaoyunque",
  );
  assert.match(f.calls[0][0], /get_credit_balance$/);
});
for (const balance of ["0", "123", "9223372036854775807"]) {
  test(`credit query preserves exact balance ${balance}`, async () => {
    const f = fixture({ total_remain_amount: balance });
    assert.deepEqual(await provider.actions!.queryCredits(f.ctx), {
      ok: true,
      text: {
        "zh-CN": `剩余积分：${balance}`,
        en: `Credits remaining: ${balance}`,
      },
    });
    assert.equal(f.calls[0][1].body, "{}");
    assert.equal(f.calls[0][1].headers.Authorization, "Bearer key");
  });
}
for (const balance of [null, "", "NaN", "1.5", 123]) {
  test(`credit query rejects malformed balance ${balance}`, async () => {
    const f = fixture({ total_remain_amount: balance });
    await assert.rejects(
      async () => provider.actions!.queryCredits(f.ctx),
      /balance|amount/,
    );
  });
}
test("credit query preserves service failures", async () => {
  const f = fixture();
  f.respond({ status: 401, body: { ret: "401", errmsg: "Access Key 已失效" } });
  await assert.rejects(
    async () => provider.actions!.queryCredits(f.ctx),
    /Access Key 已失效/,
  );
});
for (const [state, status] of [
  [1, "queued"],
  ["2", "running"],
  [4, "failed"],
  [5, "cancelled"],
  [99, "unknown"],
]) {
  test(`maps state ${state} to ${status} after restart`, async () => {
    const f = fixture({
      run_id: "run",
      thread_id: "thread",
      run_state: state,
      fail_reason: { code: 42, message: "余额不足" },
    });
    const result = await provider.video!.query(
      JSON.parse(JSON.stringify(queryInput)),
      f.ctx,
    );
    assert.equal(result.status, status);
    assert.equal(f.calls[0][1].timeoutMs, 300000);
    if (result.status === "failed")
      assert.equal(result.error.message, "余额不足");
    assert.deepEqual(f.calls[0][1].body.value, {
      run_id: "run",
      thread_id: "thread",
    });
  });
}
test("successful query returns video only, not auxiliary images", async () => {
  const f = fixture({
    run_id: "run",
    thread_id: "thread",
    run_state: "3",
    video_urls: ["https://example.com/v.mp4"],
    image_urls: ["https://example.com/i.png"],
  });
  assert.deepEqual(await provider.video!.query(queryInput, f.ctx), {
    status: "succeeded",
    outputs: [{ kind: "url", url: "https://example.com/v.mp4" }],
  });
  assert.deepEqual(f.logs, []);
});
test("multiple video outputs return only the first video", async () => {
  const f = fixture({
    run_id: "run",
    thread_id: "thread",
    run_state: 3,
    video_urls: [
      "https://example.com/first.mp4",
      "https://example.com/second.mp4",
    ],
  });
  assert.deepEqual(await provider.video!.query(queryInput, f.ctx), {
    status: "succeeded",
    outputs: [{ kind: "url", url: "https://example.com/first.mp4" }],
  });
  assert.deepEqual(f.logs, [
    {
      message: "Xiaoyunque returned multiple videos; using only the first",
      data: {
        remoteTaskId: "run",
        threadId: "thread",
        outputCount: 2,
        selectedIndex: 0,
      },
    },
  ]);
});
for (const urls of [
  [],
  ["file:///private/x", "https://example.com/2"],
  ["file:///private/x"],
]) {
  test(`does not silently accept unsupported outputs ${urls.length}`, async () => {
    const f = fixture({
      run_id: "run",
      thread_id: "thread",
      run_state: 3,
      video_urls: urls,
    });
    assert.equal(
      (await provider.video!.query(queryInput, f.ctx)).status,
      "unknown",
    );
  });
}
test("rejects missing state, mismatched identities and malformed receipts", async () => {
  const f = fixture();
  await assert.rejects(
    provider.video!.query({ remoteTaskId: "run" }, f.ctx),
    /thread_id/,
  );
  assert.equal(f.calls.length, 0);
  await assert.rejects(provider.video!.query(queryInput, f.ctx), /identity/);
  f.respond({
    status: 200,
    body: { ret: 0, data: { run: { run_id: "run" } } },
  });
  await assert.rejects(provider.video!.submit(f.input, f.ctx), /thread_id/);
});
test("rejects unuploaded references and unsupported resolutions before network", async () => {
  const f = fixture();
  f.input.request.resolution = "1080p";
  await assert.rejects(provider.video!.submit(f.input, f.ctx), /parameters/);
  f.input.request.resolution = "480p";
  f.input.request.mode = "reference";
  f.input.references = [
    {
      assetId: "a",
      role: "reference_image",
      mimeType: "image/png",
      fileSize: 1,
      mediaInfo: {},
      source: { kind: "url", url: "https://example.com/x" },
    },
  ];
  await assert.rejects(provider.video!.submit(f.input, f.ctx), /uploaded/);
  assert.equal(f.calls.length, 0);
});
test("preserves service errors and rejects missing key and non-JSON responses", async () => {
  const f = fixture();
  f.respond({ status: 200, body: { ret: "42", errmsg: "余额不足" } });
  await assert.rejects(provider.video!.submit(f.input, f.ctx), /余额不足/);
  f.respond({ status: 502, body: "<html>bad gateway</html>" });
  await assert.rejects(provider.video!.submit(f.input, f.ctx), /invalid JSON/);
  f.ctx.secrets.get = async () => null;
  await assert.rejects(provider.video!.submit(f.input, f.ctx), /Access Key/);
});
