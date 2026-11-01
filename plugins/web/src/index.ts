import type { PluginSetup } from "reveric-plugin-sdk";
import definitions from "./definitions.json";
import { webSearch } from "./search";
import { webFetch } from "./fetch";
export function apply(setup: PluginSetup): void {
  setup.tools.register({
    ...definitions.WebSearch,
    display: { summaryArg: "query", result: "items", resultPath: "results" },
    handler: (input, context) => webSearch(context, input),
  });
  setup.tools.register({
    ...definitions.WebFetch,
    display: { summaryArg: "url", result: "text", resultPath: "content" },
    handler: (input, context) => webFetch(context, input),
  });
}
