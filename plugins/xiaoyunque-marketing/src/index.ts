import type { PluginSetup } from "reveric-plugin-sdk";
import { createXiaoyunqueProvider } from "../../xiaoyunque/src/provider";

export const provider = createXiaoyunqueProvider("marketing");
export function apply(setup: PluginSetup): void {
  setup.provider.register(provider);
}
