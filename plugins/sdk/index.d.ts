// Reveric plugin SDK. These declarations and their comments are the
// authoritative contract between a plugin and the Host.
//
// Lifecycle
// - The entry bundle exports `apply(setup: PluginSetup)`. `apply` only
//   registers handlers; no Host API is available.
// - Business plugins share one runtime, each with its own isolated context.
//   Loading a plugin runs `apply`
//   once; subsequent calls reuse its handlers and module state. Calls may overlap
//   while awaiting Host APIs. TSX pages retain their own independent runtimes.
// - Updating, disabling or unloading a plugin destroys its context, including
//   globals and intrinsic changes. Persist durable state with
//   `storage` or `sqlite`; module state is only a cache.
// - Each handler receives a context for its phase and invocation. Do not retain
//   a context for use by another call; the setup object has no data access.
// - Cancellation or a wall-clock timeout revokes the invocation's Host APIs
//   and rejects pending bridge waits. The Host waits up to 500 ms for its JS
//   execution to finish. If it does not stop, the shared runtime is closed and
//   rebuilt; other outstanding calls fail with `plugin_runtime_reset`.
//   A Host call attempted after an invocation has finished also retires the
//   runtime, including detached work that outlives its handler. Unhandled
//   rejections from detached work are logged; they do not fail later calls.
// - Continuous JS budget violations and memory exhaustion also rebuild the
//   shared runtime. Plugins reload before their next use. Completed writes are
//   not rolled back and the runtime never replays failed calls. Keep
//   related writes in one `sqlite.transaction`.
//
// Results
// - Handler results must be strict JSON: null, boolean, finite number,
//   string, array, or plain object. Object properties whose value is
//   `undefined` are omitted. Anything else (bigint, Uint8Array, NaN,
//   functions, Date or other class instances) fails the call with
//   `plugin_invalid_result` naming the offending path. SQLite rows may
//   contain bigint or Uint8Array values; convert them before returning.
//
// Errors
// - Throw `PluginError` for expected failures. The Host reports its `code`
//   as is: a tool call returns `{ok: false, plugin_id, error_code: code,
//   error: message}` to the agent, a task records the code, and a settings
//   action reports it like `ActionResult.code`.
// - A rejected Host API call throws a `PluginHostError`, which also carries
//   a code. Letting it propagate reports that code the same way.
// - Any other uncaught error is reported as `plugin_error` with its stack.
//   Error codes must match /^[a-z][a-z0-9_]{0,63}$/; other codes are treated
//   as unexpected errors.

export type Json =
  null | boolean | number | string | Json[] | { [key: string]: Json };
export type JsonObject = { [key: string]: Json };

/**
 * User-visible text. A string is shown in every language; an object maps
 * language tags to text, e.g. `{ "en": "Memory", "zh-CN": "记忆" }`. The
 * Host shows the current UI language, then zh-CN, then en, then the first
 * entry. Applies to plugin.json `name`, `description`, setting `title`,
 * `description` and option `label`, action `title`, and to view titles,
 * task titles and `ToolDisplay.title`.
 */
export type PluginText = string | { readonly [languageTag: string]: string };

/** Expected failure with a stable machine-readable code. */
export declare class PluginError extends Error {
  constructor(code: string, message: string);
  readonly code: string;
}

/**
 * Rejection from a Host API. Common codes: `invalid_argument`,
 * `permission_denied`, `invalid_scope`, `not_found`, `version_conflict`,
 * `draft_conflict`, `too_large`, `network`, `timeout`, `unavailable`.
 */
export interface PluginHostError extends Error {
  readonly code: string;
}

/** Whether `error` is a Host API rejection, optionally with the given code. */
export declare function isHostError(
  error: unknown,
  code?: string,
): error is PluginHostError;

export interface PluginInfo {
  readonly id: string;
  readonly version: string;
}

/**
 * Diagnostics written to the Host log with the plugin id. Calls never throw
 * and do not wait for the Host. Known secret values are redacted.
 */
export interface PluginLog {
  info(message: string, data?: Json): void;
  warn(message: string, data?: Json): void;
  error(message: string, data?: Json): void;
}

// ---------------------------------------------------------------------------
// Setup

/**
 * Passed to `apply`. Only registration is available.
 * Manifest `settings.fields` declares form fields; `settings.actions` declares
 * action titles and required fields. `tasks[id]` declares title and
 * intervalMinutes (15–10080); register only its handler here.
 * Manifest `pages[id]` declares title, location (`home.plugin`), protocol and
 * source. TSX pages mount directly from their source without registration.
 * A2UI pages declare action names and optional onMount; bind each action here.
 * Every declared task and action needs exactly one handler. Missing, extra or
 * duplicate registrations fail activation. Tools and prompts stay code-defined.
 */
export interface PluginSetup {
  readonly plugin: PluginInfo;
  readonly tools: { register(tool: ToolRegistration): void };
  readonly prompts: {
    /** Reference data added to the conversation before model requests. */
    context(provider: PromptRegistration): void;
    /** Replaces the whole system prompt of agents in the listed session modes. */
    system(provider: SystemPromptRegistration): void;
  };
  readonly tasks: { register(id: string, handler: TaskHandler): void };
  readonly pages: {
    /** Binds one action declared in plugin.json `pages[id].actions`. */
    registerAction(id: string, name: string, handler: PageActionHandler): void;
  };
  readonly settings: {
    /**
     * Registers the handler of an action declared in plugin.json `settings.actions`.
     * Every declared action must be registered and no other name may be.
     * Actions run even while the plugin is disabled, so a user can check a
     * configuration before enabling it.
     */
    registerAction(
      name: string,
      handler: (context: ActionContext) => Promise<ActionResult>,
    ): void;
  };
}

/** Signature of the entry's exported `apply`. */
export type PluginApply = (setup: PluginSetup) => void | Promise<void>;

// ---------------------------------------------------------------------------
// Handler contexts

/** Host APIs shared by every handler phase except prompts. */
export interface PluginServices {
  readonly plugin: PluginInfo;
  readonly log: PluginLog;
  readonly http: PluginHttp;
  readonly storage: PluginStorage;
  readonly settings: PluginSettings;
  readonly secrets: PluginSecrets;
  /** Requires plugin.json `database`; otherwise calls fail with `database_not_declared`. */
  readonly sqlite: PluginSqlite;
  /** Requires the `ai.generateText` permission; otherwise calls fail with `permission_denied`. */
  readonly ai: PluginAi;
}

/** Chapter and character access, limited to the work of the current request or page. */
export interface WorkData {
  readonly chapters: DataApi<ChapterSummary, ChapterRecord>;
  readonly characters: DataApi<CharacterSummary, CharacterRecord>;
}

/** The agent request a tool call or prompt belongs to. */
export interface AgentRequest {
  /** New for every model request, shared by the prompt and the tool calls of that request. */
  readonly requestId: string;
  readonly sessionId: string;
  /** Work of the chat session; null outside a work. */
  readonly workId: string | null;
  /**
   * Agent of the request: `orchestrator` for the main chat agent, the expert
   * id for sub-agents it spawns, the character id in roleplay, monologue and
   * theater, the participant id or `summarizer` in council. Providers return
   * null to skip agents they do not target.
   */
  readonly agentId: string | null;
  /** Session mode, one of {@link SessionMode}, or `headless` outside a session. */
  readonly mode: SessionMode | "headless";
}

/** Context of a tool call. Time limit: 60 seconds. */
export interface ToolContext extends PluginServices, WorkData {
  /** Unique per call. */
  readonly callId: string;
  readonly request: AgentRequest;
}

/** Session modes whose agents a system prompt provider can target. */
export type SessionMode =
  "chat" | "council" | "monologue" | "theater" | "roleplay";

/**
 * Context of a prompt provider. Providers run within a small time budget
 * before model requests, so only read access is available.
 */
export interface PromptContext {
  readonly plugin: PluginInfo;
  readonly log: PluginLog;
  readonly request: AgentRequest;
  readonly sqlite: Pick<PluginSqlite, "query">;
  readonly storage: Pick<PluginStorage, "get">;
  readonly settings: PluginSettings;
}

/**
 * Context of a scheduled task run. Time limit: 5 minutes overall and
 * 2 seconds of continuous JavaScript execution.
 */
export interface TaskContext extends PluginServices {
  readonly runId: string;
  readonly trigger: "scheduled" | "manual";
  /** Milliseconds since the epoch. */
  readonly scheduledAt: number;
}

/**
 * Context of a settings action. Time limit: 20 seconds. `settings.get` and
 * `secrets.get` return the unsaved values of the settings form.
 */
export interface ActionContext extends PluginServices {
  readonly callId: string;
}

/** The plugin page a view handler runs for. */
export interface PageInfo {
  readonly viewId: string;
  /** Unique per opened page. */
  readonly instanceId: string;
  /** Work the page was opened in; null outside a work. */
  readonly workId: string | null;
}

/** Context of a page: TSX page code and reveric-ui-v1 view actions. */
export interface ViewContext extends PluginServices, WorkData {
  readonly page: PageInfo;
  readonly ui: {
    toast(input: { message: string }): Promise<void>;
    /**
     * Resolves true when the user confirms. `confirmLabel` (at most 40
     * characters) replaces the default confirm wording; `danger` styles the
     * confirm button as destructive.
     */
    dialog(input: {
      title: string;
      message?: string;
      confirmLabel?: string;
      tone?: "default" | "danger";
    }): Promise<boolean>;
    navigate(input: { viewId: string }): Promise<void>;
  };
  readonly view: {
    /** While dirty, the Host asks before closing the page or changing the plugin. */
    setDirty(value: boolean): Promise<void>;
  };
}

// ---------------------------------------------------------------------------
// Registrations

export interface ToolDisplay {
  /** Card title; defaults to the tool name. */
  title?: PluginText;
  /** Name of an input property shown as the card summary. */
  summaryArg?: string;
  /** How the card previews a successful result. */
  result?: "items" | "text" | "json";
  /**
   * Name of a top-level field of the result object holding the previewed
   * value (not a nested path). `items` expects an array of objects with
   * `title`/`url` and optional `snippet`; `text` expects a string.
   */
  resultPath?: string;
  /** Package path of a reveric-ui-v1 card; requires `result`. */
  view?: { protocol: "reveric-ui-v1"; source: string };
}

export interface ToolRegistration {
  /** /^[A-Za-z][A-Za-z0-9_]{0,63}$/, unique among Host and plugin tools. */
  name: string;
  /** Shown to the model. */
  description: string;
  /** JSON Schema with `type: "object"`. */
  inputSchema: Json;
  display?: ToolDisplay;
  /**
   * Returns a JSON object of at most 256 KB, passed to the agent as is.
   * Throw `PluginError` to fail; see "Errors" above.
   */
  handler(input: JsonObject, context: ToolContext): Promise<JsonObject>;
}

export interface PromptRegistration {
  /** /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/, unique across context and system providers. */
  id: string;
  /**
   * Runs before every model request, including each round of a tool loop.
   * The text is added to the conversation as reference data only when it
   * differs from the last text of this provider in the conversation, and
   * stays in the history afterwards. Returning null after text was added
   * records that the plugin has no content now.
   * Up to 1000 tokens per plugin and 2000 in total. Output beyond the budget,
   * failures and timeouts add nothing for that request, keep the previous
   * text in effect and are shown in the plugin settings.
   */
  handler(context: PromptContext): Promise<string | null>;
}

export interface SystemPromptRegistration {
  /** /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/, unique across context and system providers. */
  id: string;
  /** Non-empty list of distinct session modes this provider replaces. */
  modes: SessionMode[];
  /**
   * Runs once at the start of each agent run in a listed mode, including
   * sub-agents and every participant of multi-agent modes; `request.agentId`
   * tells them apart. The returned text replaces the whole system prompt for
   * that run; null keeps the default one. Notes the Host adds for connected
   * MCP servers still follow it. Up to 8000 tokens.
   * When more than one enabled provider covers a mode, none of them applies.
   * Output beyond the budget, failures and timeouts keep the default prompt
   * and are shown in the plugin settings.
   */
  handler(context: PromptContext): Promise<string | null>;
}

/** Binds a task declared in plugin.json `tasks`; metadata lives in the manifest. */
export type TaskHandler = (
  context: TaskContext,
) => Promise<{ summary?: string } | void>;

/** A2UI action returning updateComponents / updateDataModel messages (at most 1 MB). */
export type PageActionHandler = (
  data: JsonObject,
  event: JsonObject,
  context: ViewContext,
) => Promise<Json[]>;

/** Result of a settings action. */
export interface ActionResult {
  ok: boolean;
  /**
   * "unauthorized", "network" and "timeout" are shown with host wording;
   * any other code is shown as a generic failure.
   */
  code?: string;
  /** Written to the host log only; never shown to the user. */
  message?: string;
}

// ---------------------------------------------------------------------------
// Host APIs

export interface HttpRequest {
  method?: "GET" | "POST" | "PUT" | "PATCH" | "DELETE" | "HEAD";
  headers?: Record<string, string>;
  body?: string;
  timeoutMs?: number;
  maxBytes?: number;
  responseType?: "text" | "base64";
}
export interface HttpResponse {
  status: number;
  /** Final URL after redirects. */
  url: string;
  headers: Record<string, string>;
  body: string;
}
export interface PluginHttp {
  fetch(url: string, init?: HttpRequest): Promise<HttpResponse>;
}

/** Isolated persistent JSON values. */
export interface PluginStorage {
  /** Key: 1–256 characters. Resolves null when the key is unset. */
  get(key: string): Promise<Json | null>;
  set(key: string, value: Json): Promise<void>;
  /** Hides the stored value. */
  remove(key: string): Promise<void>;
}

/** Values of plugin.json `settings.fields` fields that are not secrets. */
export interface PluginSettings {
  /**
   * Resolves the saved value, else the declared default, else null.
   * A `model` field resolves to `{ providerId, model }`, which can be spread
   * into `ai.generateText`; null means the user's default chat model. A model
   * the user later removed fails with `model_not_found`.
   */
  get(key: string): Promise<Json | null>;
}

/** Values of plugin.json `settings.fields` fields of type `secret`. */
export interface PluginSecrets {
  get(key: string): Promise<string | null>;
}

/** A chat model the user has configured and enabled. */
export interface AiModel {
  providerId: string;
  /** Provider name shown in the app. */
  providerName: string;
  model: string;
  /** Model name shown in the app. */
  modelName: string;
  /** Whether this is the user's default chat model. */
  isDefault: boolean;
  /** Accepted `reasoningEffort` values, weakest first; null for non-reasoning models. */
  reasoningEfforts: string[] | null;
}

export interface GenerateTextInput {
  system: string;
  /** Non-empty. */
  prompt: string;
  /**
   * Model from `listModels()`; give both or neither. Without them the user's
   * default chat model is used, failing with `model_not_configured` when there
   * is none. An unknown pair fails with `model_not_found`.
   */
  providerId?: string;
  model?: string;
  /** 1–65536, sent to the provider as is. Defaults to the model's output limit. */
  maxOutputTokens?: number;
  /**
   * One of the model's `reasoningEfforts`; other values fail with
   * `invalid_argument`. Defaults to the effort the user chose for the model.
   */
  reasoningEffort?: string;
}

/**
 * Why the model stopped. `length` means the output hit `maxOutputTokens` and
 * `text` is truncated (possibly empty when reasoning used the whole budget).
 */
export type FinishReason =
  "stop" | "length" | "content_filter" | "tool_calls" | "unknown";

export interface GenerateTextResult {
  text: string;
  finishReason: FinishReason;
  /** Model that produced the text. */
  providerId: string;
  model: string;
}

/**
 * Single-turn text generation with the user's chat models. Calls incur model
 * usage, recorded under the plugin. Each request times out after 5 minutes
 * (`timeout`), and the handler's own time limit still applies. Provider
 * failures reject with `ai_error` carrying the provider message.
 */
export interface PluginAi {
  listModels(): Promise<AiModel[]>;
  generateText(input: GenerateTextInput): Promise<GenerateTextResult>;
}

export type SqlValue = null | string | number | bigint | Uint8Array;
export interface SqlStatement {
  sql: string;
  /** Positional parameters. Numbers must be finite and safe integers; use bigint beyond that. */
  params?: SqlValue[];
}
export interface SqlWriteResult {
  changes: number;
  lastInsertRowId: bigint | null;
}
/** The plugin's private SQLite database, migrated from plugin.json `database`. */
export interface PluginSqlite {
  query(statement: SqlStatement): Promise<Record<string, SqlValue>[]>;
  execute(statement: SqlStatement): Promise<SqlWriteResult>;
  /** Runs all statements atomically. */
  transaction(statements: SqlStatement[]): Promise<SqlWriteResult[]>;
}

/**
 * Work-scoped access to Host records. Requires the `<resource>.read`
 * permission, and `<resource>.write` for `update`. Calls fail with
 * `invalid_scope` when there is no current work.
 */
export interface DataApi<S, T> {
  /**
   * Summaries in display order (chapters in reading order, characters in
   * their list order). `limit` 1–100, default 20; `offset` default 0. Read
   * the full record with `get`.
   */
  list(input?: {
    limit?: number;
    offset?: number;
  }): Promise<{ items: S[]; hasMore: boolean }>;
  get(input: { id: string }): Promise<T>;
  /**
   * Changes the given fields. Fails with `version_conflict` when the record
   * no longer has `expectedVersion`, and with `draft_conflict` while the
   * record has pending changes. The change is recorded in work history.
   */
  update(input: {
    id: string;
    expectedVersion: string;
    patch: Partial<Omit<T, "id" | "workId" | "version">>;
  }): Promise<T>;
}

export interface ChapterSummary {
  id: string;
  /** Changes whenever any field of the record changes. */
  version: string;
  title: string;
  /** 1-based position in reading order. */
  order: number;
}
export interface ChapterRecord {
  id: string;
  workId: string;
  version: string;
  title: string;
  outline: string;
  content: string;
}
export interface CharacterSummary {
  id: string;
  version: string;
  name: string;
  /** 1-based position in the character list. */
  order: number;
}
export interface CharacterRecord {
  id: string;
  workId: string;
  version: string;
  name: string;
  role: string;
  gender: string;
  biography: string;
  description: string;
  appearance: string;
  identity: string;
  age: string;
  motivation: string;
  arc: string;
  personality: string;
  currentState: string;
}
