import type { JsonObject, PluginSetup } from "reveric-plugin-sdk";
import { forgetFromTool, prompt, saveFromTool, syncMemoryBadge } from "./data";
import { organize } from "./organize";

export function apply(setup: PluginSetup) {
  setup.tools.register({
    name: "MemorySave",
    description:
      "保存或修改用户的跨作品长期创作偏好。仅在用户明确要求记住或修改偏好（如「记住我喜欢…」「以后都…」「把之前那条偏好改成…」）时调用；禁止擅自推断写入，禁止记录单部作品的人设、关系、剧情或临时对话。",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["content"],
      properties: {
        id: {
          type: "string",
          description:
            "可选；仅修改已有偏好时传入上下文方括号中的 ID，新建时不要传。",
        },
        content: {
          type: "string",
          minLength: 1,
          maxLength: 300,
          description:
            "跨作品通用的精炼偏好，提炼脱离当前作品仍成立的原则而非具体个例；所有偏好共享有限注入预算，单条只记一个维度，建议百字以内。",
        },
        topic: {
          type: "string",
          maxLength: 40,
          description:
            "可选短主题词（如 文风、对话、节奏、协作）；优先复用已有主题，留空表示通用。",
        },
        priority: {
          type: "integer",
          enum: [0, 1],
          description: "0 普通；1 核心，优先注入聊天参考。",
        },
        enabled: {
          type: "boolean",
          description: "是否启用注入，默认 true。",
        },
      },
    },
    display: {
      title: { "zh-CN": "记住创作偏好", en: "Save writing preference" },
      summaryArg: "content",
      result: "json",
    },
    handler: async (input, context) => {
      const result = (await saveFromTool(
        context.sqlite,
        input,
      )) as unknown as JsonObject;
      await syncMemoryBadge(context.sqlite, context.storage);
      return result;
    },
  });

  setup.tools.register({
    name: "MemoryForget",
    description:
      "忘掉一条跨作品创作偏好。仅在用户明确要求忘记或删除某条已记住的偏好时调用，传入上下文方括号中的 ID。",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["id"],
      properties: {
        id: {
          type: "string",
          description: "要遗忘的偏好 ID（来自上下文参考方括号中）。",
        },
      },
    },
    display: {
      title: { "zh-CN": "遗忘创作偏好", en: "Forget writing preference" },
      summaryArg: "id",
      result: "json",
    },
    handler: async (input, context) => {
      const result = (await forgetFromTool(
        context.sqlite,
        input,
      )) as unknown as JsonObject;
      await syncMemoryBadge(context.sqlite, context.storage);
      return result;
    },
  });

  setup.prompts.context({
    id: "memory",
    handler: async (context) => (await prompt(context.sqlite)).text || null,
  });

  setup.tasks.register("organize", organize);
}
