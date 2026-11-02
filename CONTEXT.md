# Reveric AI

This context defines the language used around Reveric's AI agent and prompt behavior.

## Language

### Entity Relations

**Current Relation State**:
The latest confirmed description of a relation between two entities, distinct
from the earlier states that relation has passed through.
_Avoid_: latest recorded change as story chronology, historical search match

**Primary Relation Type**:
The single relationship meaning selected to characterize a relation's current
state. Other simultaneous meanings may provide context without becoming
additional primary types; brothers who are enemies may be characterized as
enemies while their kinship remains part of the supporting explanation.
_Avoid_: exhaustive list of simultaneous relationships, multiple primary types

**Relation Change History**:
The account of an individual relation's actual story changes and their
supporting evidence, distinct from its Current Relation State. Mistaken
entries and their corrections are not story changes.
_Avoid_: correction audit trail, historical relation search, historical graph
snapshot

**Ended Relation**:
A relation confirmed to no longer hold between its participants, with its
former type and evidence retained. Ending one relation neither establishes a
replacement relation nor ends other relations between the same participants.
_Avoid_: deleted relation, no relation of any kind, automatic replacement type

**Relation Record Correction**:
A correction to the recorded description of a relation's current state,
without claiming that a new change occurred in the story. It is distinct from
a Relation Transition and from removing an entirely mistaken change.
_Avoid_: new story event, correction event in relation history

**Relation Transition**:
An evidenced change of an existing relation into another type, such as lovers
becoming friends, with continuity of that relation and its history. It is
distinct from ending a relation without a confirmed subsequent relationship.
_Avoid_: ending every type change, replacing all relations between two entities

**Relation Resumption**:
An evidenced restoration of a previously ended relation between the same
participants. Its earlier active periods, termination, and resumption belong
to one continuous relation history.
_Avoid_: automatic merging by participant pair, erasing the ended period

### Work Lineage

**Work Type**:
The primary classification of a work, including Original, Adaptation, Sequel, Fanfic, Derivative, and Reference. For a work with a Source Novel, Work Type states how the work relates to that source. Adaptation is offered only when creating a screenplay — adapting a novel into another novel is not a supported flow. Derivative is a legacy value: existing works keep it, but no creation entry point offers it.
_Avoid_: source relation type, lineage kind

**Source Novel**:
The single primary novel from which a work is adapted, continued, or written as fanfiction. Reference material and stylistic inspiration are not Source Novels.
_Avoid_: inspiration, reference book, source work

### AI Agents

**Chat Orchestrator**:
The single invisible primary agent behind the chat entry point. Users do not choose it; it coordinates direct replies, tool use, and delegation to **Chat Subagents**.
_Avoid_: selectable agent, default agent, visible agent, orchestrator profile

**Chat Subagent**:
A specialized agent that can be delegated work by the **Chat Orchestrator**. Chat Subagents may be user-managed or internal; they are the extensible specialization layer for chat after retiring selectable planner/writer/artist/viber primary agents.
_Avoid_: primary agent, agent selector option

**Internal Chat Subagent**:
A Chat Subagent available to the **Chat Orchestrator** but not exposed as a user-managed specialization. Chronicler is an Internal Chat Subagent.
_Avoid_: user subagent, primary agent

**Spawn Session**:
An AI session created when the **Chat Orchestrator** delegates a task to a **Chat Subagent** through SpawnAgent. A Spawn Session belongs under its source top-level chat session and records the subagent's own conversation history; it is not a top-level chat session.
_Avoid_: active chat session, agent profile, main chat

**Spawn Session Reuse**:
Continuing a compatible **Spawn Session** when the Chat Orchestrator delegates another task to the same Chat Subagent. Reuse means the subagent keeps its own prior working context; it does not mean copying the source chat session into the subagent.
_Avoid_: session handoff, main chat reuse, agent switch

**Background Delegation（后台委派）**:
A Chat Subagent assignment that runs while the source chat remains available for other work, with completion brought back to the Chat Orchestrator for processing. The Chat Orchestrator may choose it for independent work unless the user directs otherwise.
_Avoid_: background chat session, unattended task schedule

**Stop Reply（停止回复）**:
A user action that stops the Chat Orchestrator's current work while independently running Chat Subagent tasks continue. Their completion may still wake the Chat Orchestrator to process the result, without automatically resuming the stopped work.
_Avoid_: stop all, cancel the conversation

**Stop Subtask（停止某个子任务）**:
A user action that stops one selected Chat Subagent task while other work continues.
_Avoid_: stop reply, stop all subagents

**Stop All（全部停止）**:
A user action that stops the Chat Orchestrator's current work and its running Chat Subagent tasks in the same source chat session. Late notifications from that stopped work cannot restart execution.
_Avoid_: stop every chat session, pause reply

**Session Handoff**:
A continuation of work from one AI session in a new AI session with fresh context, initially carrying only a source-conversation reference and the user's current instruction. Source history is consulted on demand, without automatically copying messages or generating a handoff summary; changing agents is not the handoff boundary.
_Avoid_: session fork, full transcript copy, agent handoff, handoff to agent, switch agent

**Source Session Reference**:
A reference identifying the source conversation of a Session Handoff so its history can be consulted on demand. It does not retain a copy of that history or extend the source conversation's retention period.
_Avoid_: history snapshot, retained conversation, session parent

**Session History**:
The recorded conversation of any saved AI session, including ordinary chat, Chat Subagents, Workflow Execution Sessions, council, monologue, theater, and roleplay. A Session History belongs to its source work and can be consulted from other works; discovery defaults to the current work unless another work is explicitly selected.
_Avoid_: current-session-only history, shared conversation across works

**Tool Record**:
A record of a tool invocation and its outcome within Session History, including its arguments, result, and execution status. It remains part of the source conversation even when consulted separately from the surrounding dialogue.
_Avoid_: tool role, tool-result-only history

**AI Context Reference**:
A pointer the user attaches to chat so the **Chat Orchestrator** can read a specific novel workspace resource before answering. It carries where to read from, not the resource content itself.
_Avoid_: pasted context, embedded context, handoff

**Active Workspace Target**:
The persisted novel workspace resource currently open in the editor UI. It is provided automatically to the **Chat Orchestrator** as location metadata only, so the orchestrator knows which saved resource the user is looking at without receiving that resource's content unless it explicitly reads it through tools. Unsaved drafts are not Active Workspace Targets because they have no stable resource identity.
_Avoid_: active content, live context, implicit reference, draft target

**AI Shortcut Action**:
A built-in or user-created action, reusable across novels, that can appear on one or more novel workspace object types, prepares a task instruction for chat, and may attach one or more **AI Context References**. It is not a **Session Handoff** because it does not transfer context between AI sessions.
_Avoid_: handoff shortcut, agent handoff button, quick handoff

**AI Shortcut Action Prompt**:
The editable task template used by an **AI Shortcut Action** to prepare chat instructions. It is scoped to a shortcut task and is not a standing behavior rule for the **Chat Orchestrator**.
_Avoid_: agent rule, system prompt, global prompt

**Workflow**:
A user-defined reusable graph of AI work and deterministic control-flow nodes. Workflow definitions are global reusable records; novels use them through **Workflow Installations** instead of owning separate novel-scoped Workflow definitions.
_Avoid_: workflow template, shortcut action, agent workflow evaluation, step list

Workflow definitions are reusable. Per-novel availability, run-entry display order, and auto-trigger configuration belong to Workflow Installations.

Workflow definitions are managed from the Home area. Novel Editor Workflow UI manages Workflow Installations and Runs, not Workflow definitions.

Workflow definitions do not have a separate availability flag. A Workflow is available in a novel only when a Workflow Installation exists for that novel; uninstalling removes future availability while preserving historical Workflow Runs.

**Workflow Installation**:
The per-novel relationship that makes a **Workflow** available in one target novel. Installing a Workflow means it can always be started manually for that novel; optional auto-trigger configuration may also create runs on a schedule.
_Avoid_: workflow trigger, workflow copy, workflow override

A Workflow may have many Workflow Installations. A Workflow Installation belongs to exactly one Workflow and one novel.

**Workflow Auto Trigger**:
The automatic run creation mode on a **Workflow Installation**. `autoTriggerType: none` means no automatic runs; `autoTriggerType: schedule` means scheduled automatic runs. V1 scheduled auto triggers support daily, weekly, and monthly schedules only.
_Avoid_: manual trigger, advancement mode, edge condition

**Workflow Graph**:
The node-and-edge definition stored by a **Workflow** and snapshotted by a **Workflow Run**. A Workflow Graph owns the start node, nodes, and edges; it is not flattened into ordered steps.
_Avoid_: steps, step list, execution order

**Workflow Node**:
One executable or control-flow unit inside a **Workflow Graph**. V1 supports Agent Nodes, Loop Nodes, and Split Nodes.
_Avoid_: workflow step, task, agent skill

**Agent Node**:
A **Workflow Node** that creates a **Workflow Execution Session** and produces text or structured output. Agent Nodes do not own built-in acceptance or review gates; quality judgment belongs in another Agent Node plus a Split Node when branching is needed.
_Avoid_: workflow step with acceptance, self-reviewing step

Each Agent Node uses the agent selected by the user for that node. Workflow runtime does not add hidden review-only or read-only behavior to Agent Nodes.

**Split Node**:
A deterministic **Workflow Node** that evaluates a **Condition** and selects a true or false edge. Split Nodes do not call AI.
_Avoid_: ifelse node, AI branch judge, review step

**Loop Node**:
A **Workflow Node** that repeatedly executes a child **Workflow Graph** according to explicit loop configuration.
_Avoid_: repeated steps, implicit cycle

V1 Loop Nodes use fixed counts and allow one or more Agent Nodes inside their child graph.

**Workflow Edge**:
A directed connection between **Workflow Nodes**. Edges may be unconditional or branch-specific.
_Avoid_: next step, transition prompt

**Condition**:
A deterministic structured predicate built by a reusable condition builder and evaluated against caller-provided data. Workflow Split Nodes use Conditions for true/false branching, but the Condition module is not Workflow-specific and does not invoke AI.
_Avoid_: review prompt, judge instruction, natural-language condition

Condition fields are configured by the caller. In Workflow, those fields expose run input, runtime variables, node outputs, changed paths, and loop state.

**Workflow Run**:
A single run record for a **Workflow** in a specific novel. A Workflow Run owns the graph snapshot for that attempt; executed runs also own node progress, outputs, changed paths, and resume state.
_Avoid_: workflow, workflow template, evaluation run

A Workflow Run status is one of `running`, `waiting`, `blocked`, `completed`, `stopped`, or `skipped`. `waiting` means deterministic control-flow has settled and a manual-advancement Workflow is waiting for the user to start the next Agent Node. `skipped` records an auto-trigger attempt that intentionally did not start execution. `skipped` Workflow Runs are inactive.

A Workflow Run uses a snapshot of the Workflow Graph captured when the run record is created; later edits to the Workflow do not change existing runs.

An in-progress Workflow Run also continues using its captured snapshot; using newer Workflow definitions requires starting a new Workflow Run.

Each novel may have at most one active Workflow Run at a time. `running`, `waiting`, and `blocked` Workflow Runs are active; `completed`, `stopped`, and `skipped` Workflow Runs are inactive.

Workflow Runs belong in the Novel Editor AI area as a Workflow section or mode.

**Workflow Node Run**:
The execution instance of one **Workflow Node** inside a **Workflow Run**. A Workflow Node Run owns that node's status, input snapshot, output snapshot, changed paths, and continuation state for the attempt.
_Avoid_: workflow step run, chat message, session state

A Workflow Node Run status is one of `pending`, `running`, `completed`, `blocked`, `failed`, or `cancelled`. `completed` means the node finished successfully and the runtime may continue through graph edges; `blocked` means runtime continuation or pending-change handling requires user action; `failed` means execution errored.

An Agent Node commits its pending changes before its Workflow Node Run becomes `completed`. Later quality-check nodes may branch to repair or blocked paths, but they do not roll back an earlier completed Agent Node.

**Workflow Session**:
An AI session created for an Agent Node's execution. A Workflow Session owns AI message and tool-call history, while the Workflow Node Run owns workflow-specific status, output, and continuation rules.
_Avoid_: chat session, workflow run, step state

**Workflow Execution Session**:
The **Workflow Session** used to execute an Agent Node.
_Avoid_: review session, chat session

A Workflow Execution Session has the same workspace tool authority as chat mode.

Rerunning an Agent Node creates a new Workflow Node Run with a new Workflow Execution Session rather than reusing the previous attempt's session.

**Workflow Run Input**:
User-provided free-text starting information for a **Workflow Run**. Workflow Run Inputs are injected into node execution by default rather than referenced through a user-authored variable syntax.
_Avoid_: prompt variable, template parameter, custom form field, UI state

**Changed Paths**:
The workspace resource paths changed and committed by a **Workflow Node Run**. Changed Paths from previous Agent Nodes are available to later nodes by default.
_Avoid_: fixed paths, repair paths, changed files

**Prompt Regression Evaluation**:
A development-time check that runs fixed agent scenarios against a real configured model to detect whether prompt or agent behavior has drifted from expected outcomes. It is not a user-facing evaluation feature and is not part of the default unit test suite.
_Avoid_: evaluation, agent test, prompt test

**Full Agent Workflow Evaluation**:
A development-time check that runs an agent through a complete tool-enabled workflow and evaluates both the process and the resulting artifacts. It may inspect tool calls, blocked or forbidden actions, data changes, and generated content.
_Avoid_: full evaluation, workflow test, agent integration test

**Judge Agent**:
An independent agent used by a Prompt Regression Evaluation to score another agent's output against a rubric. It is separate from the evaluated agent and must return a strict structured verdict.
_Avoid_: self-check, verification hook, reviewer

**Structured Run Command**:
A Reveric command executed through the Run tool using JSON fields: `command` names the command namespace, `subcommand` names the action, and `options` carries action parameters.

### Remote Interaction

**Remote Access**:
Access from one of a user's devices to the Works and agent activity held on another of that user's devices. The accessed device retains ownership of its local data; device roles depend on the direction of access rather than whether a device is a phone or a computer.
_Avoid_: IM Channel, remote desktop, cross-device data synchronization

**Accessed Device**:
The device in a Remote Access relationship that owns the Works and runs the agent sessions being accessed. Its local data and execution remain authoritative.
_Avoid_: executing device, owning device, host device, computer (as a role name)

**Accessing Device**:
The device in a Remote Access relationship that views Works and directs agent sessions held on an Accessed Device. It keeps no offline Work replica.
_Avoid_: operating device, controller, client device, phone (as a role name)

**IM Channel**:
A messaging entry point, such as WeChat, that carries messages between the user and the Remote Assistant. An IM Channel is distinct from Remote Access to another device's Works and agent activity.
_Avoid_: Remote Channel, remote access, bridge

**Remote Assistant**:
The primary agent behind an IM Channel entry point, parallel to the Chat Orchestrator (which is behind the desktop chat entry point). The Remote Assistant can list novels, start Jobs, report Job status, and share chapter reviews. In V1 it does not directly read or write novel workspaces — workspace work is delegated to Jobs. It is not a Chat Subagent and is not delegated to by the Chat Orchestrator; it is a separate entry-point agent for IM users.
_Avoid_: remote orchestrator, WeChat agent, bridge agent, remote subagent, Assistant (too generic for the glossary)

**Remote Assistant Session**:
A persistent chat session for one IM Channel user, cross-novel by design. Distinct from novel-bound chat sessions — the Remote Assistant Session routes work to specific novels via Jobs rather than being bound to one. One Remote Assistant Session per IM user.
_Avoid_: bridge session, wechat session, remote session, unbound session

**Job**:
A novel-scoped background writing execution started from a **Remote Assistant Session**. Progress and questions return on the IM Channel.
_Avoid_: Run (for this remote execution), session

### Workspace Editing

**Work**:
A top-level creative workspace whose content may be a novel or a screenplay. A Work keeps the same identity when its display title changes.
_Avoid_: Novel when referring to both content kinds, title as identity

**Workspace Resource Address**:
A stable agent-visible reference to a resource in the current Work or an explicitly identified Work. Each segment uses the identity of its actual resource kind rather than an unqualified generic identity.
_Avoid_: title-based address, generic ID path

**Active Entity Reference**:
A structured reference from an active workspace record to another entity. Active Entity References block deletion of their target; an unstructured name mention in prose is not an Active Entity Reference.
_Avoid_: text mention, historical reference, deleted-record reference

**Workspace Creation Draft**:
A temporary workspace entry the user is composing before it exists as a persisted workspace record. A Workspace Creation Draft shows explicit unsaved state and is resolved by Save, Discard, or Cancel before the user leaves it.
_Avoid_: empty record, deferred record, auto-created entry

**Workspace Draft Attachment**:
A local file the user attaches while composing a Workspace Creation Draft. Workspace Draft Attachments may already live in the novel's normal asset storage, may remain there after Discard, and are not part of a Persisted Workspace Entry until Save.
_Avoid_: temporary record attachment, generated resource, database attachment

**Persisted Workspace Entry**:
A workspace entry that already exists in the novel content database and can participate in normal autosave, history, references, and media/link workflows.
_Avoid_: saved draft, existing draft

### Character Writing Model

**Character Biography**:
The stable or cumulatively growing account of a Character's background, life history, and important past experiences. Character Biography explains what has happened to the Character, not how they look at the current story moment.
_Avoid_: current state, appearance, personality

**Character Description**:
The relatively stable portrayal of a Character's observable qualities, including appearance, voice, mannerisms, bearing, and public impression. Temporary injuries, location, possessions, and knowledge do not belong in Character Description.
_Avoid_: biography, personality, current state

**Character Personality**:
The relatively stable inner pattern of a Character, including values, desires, defenses, strengths, flaws, and contradictions. Character Personality is broader than any one reaction.
_Avoid_: behavior tag, current mood, current state

**Character Behavior Tag**:
A named behavioral tendency paired with the context in which it tends to appear. A Character Behavior Tag describes a conditional pattern rather than a permanent trait or a single current action.
_Avoid_: personality label without context, current action, agent rule

**Character Current State**:
The mutable story-now snapshot of a Character at the latest accepted point in the novel, including location, injuries or costs, possessions, abilities, emotional condition, active objective, public identity, and knowledge boundary.
_Avoid_: character description, biography, chapter summary

**Story First Appearance**:
The chapter in the current novel where a Character first appears. Story First Appearance always points to a chapter in the current novel and never to a chapter in a source novel.
_Avoid_: source-novel chapter reference, character provenance

### Canvas

**Canvas**:
An infinite pan-and-zoom visual surface that is a NovelEditor mode, novel-scoped, with zero or more per novel. A Canvas is a workspace resource type. In V1 the Canvas's content (Canvas Nodes, Canvas Edges, Canvas Stickies) is read-only to the user and authored solely by the Chat Orchestrator through canvas tools on the currently active Canvas; the Canvas entity itself (create, switch, delete, rename) may be managed by either the user or the agent.
_Avoid_: infinite canvas board, mood board (that is a use, not the thing), board, artboard, collaborative whiteboard

**Canvas Node**:
A single element placed on a Canvas. V1 has two kinds: the Canvas Reference Node and the Canvas Sticky. A Canvas Node carries its own position; position is layout data on the node, not metadata on the Canvas.
_Avoid_: canvas item, canvas widget, card

**Canvas Reference Node**:
A Canvas Node that points to an existing Persisted Workspace Entry (a character, outline, chapter, etc.) without copying its content. In V1 the Canvas is user-read-only, so a Canvas Reference Node is a pointer for organization and viewing, not an in-canvas edit surface.
_Avoid_: canvas clone, embedded resource, canvas copy

**Canvas Sticky**:
A Canvas Node holding canvas-native text (typically the agent's reasoning or note). A Canvas Sticky is owned by its Canvas; it is not an independent workspace entry and cannot be referenced by other Canvases or by AI context in V1.
_Avoid_: canvas note, canvas text, sticky entry, reusable note

**Canvas Edge**:
A visual line between two Canvas Nodes on the same Canvas, expressing an associative or sequential relationship for the reader. A Canvas Edge has no typed semantic in V1 and stays within one Canvas; it is not a Workflow Edge and is not queryable as a business relationship.
_Avoid_: canvas link, canvas relation, workflow edge on canvas

## Example Dialogue

Dev: "This prompt change looks harmless. Should we run a Prompt Regression Evaluation?"

Domain expert: "Yes. Use the fixed scenarios for the affected agent and compare whether the expected behavior still holds."

Dev: "The persona output passed. Should we use a Full Agent Workflow Evaluation for this change?"

Domain expert: "Only if the prompt change affects tool use, persisted artifacts, or multi-step agent behavior."

Dev: "Can the evaluated agent decide whether its own answer passed?"

Domain expert: "No. A Judge Agent must make the verdict from the scenario rubric."

Dev: "Which agent should the user pick before chatting?"

Domain expert: "None. Chat has one invisible Chat Orchestrator, and specialization happens through Chat Subagents."

Dev: "Should handoff mean picking a different agent?"

Domain expert: "No. A Session Handoff carries context from one AI session to another; agent choice is not the handoff boundary."

Dev: "If the user drags a chapter into chat, is that a handoff?"

Domain expert: "No. That is an AI Context Reference. It tells the Chat Orchestrator which workspace resource to read before answering."

Dev: "If a beat has a Generate Chapter Outlines button, is that a Session Handoff?"

Domain expert: "No. That is an AI Shortcut Action. It prepares the task instruction and attaches the relevant AI Context References to chat."

Dev: "Should the shortcut's editable task prompt be stored as an AgentRule?"

Domain expert: "No. It is an AI Shortcut Action Prompt. AgentRules are standing chat behavior rules, while shortcut prompts are task templates for specific user-triggered actions."

Dev: "Can one custom shortcut appear in multiple workspace places?"

Domain expert: "Yes. An AI Shortcut Action can be reused across novels and can be shown on multiple workspace object types."

Dev: "When the user starts a character but has not saved it yet, is that an empty database record?"

Domain expert: "No. It is a Workspace Creation Draft until the user chooses Save. If they try to leave after typing content, they must choose Save, Discard, or Cancel."

Dev: "Can autosave create the database row for a Workspace Creation Draft?"

Domain expert: "No. Autosave applies to Persisted Workspace Entries; a Workspace Creation Draft needs an explicit Save."

Dev: "If the user uploads an avatar before saving a character, is that avatar tied to a character ID?"

Domain expert: "No. It is a Workspace Draft Attachment until Save; its file name does not encode the future workspace entry ID."

Dev: "If a user wants to use the same Workflow in two novels, should we copy the Workflow definition?"

Domain expert: "No. Keep one global Workflow definition and create one Workflow Installation per novel."

Dev: "If the user starts a Workflow and later edits the Workflow definition, should the running Workflow Run pick up the new graph?"

Domain expert: "No. A Workflow Run uses the Workflow snapshot captured when the run record is created. Use a new Workflow Run for newer definitions."

Dev: "Can an Agent Node modify chapter content or settings?"

Domain expert: "Yes. The Workflow Execution Session has chat-level workspace tool authority. Later nodes decide where the Workflow Run goes next, not whether the Agent Node was allowed to make changes."

Dev: "If a quality-check Agent Node returns a failed verdict, should the Workflow roll back the previous Agent Node's content changes?"

Domain expert: "No. The changes remain pending. The graph can branch to a repair node, stop as blocked, or wait for user action, but it must not silently roll changes back."

Dev: "Can the Agent Node that produced content judge its own output and decide the branch?"

Domain expert: "No. If the graph needs a quality verdict, add a separate Agent Node that returns structured output, then branch with a Split Node."

Dev: "Does rerunning an Agent Node reuse the old Workflow Execution Session?"

Domain expert: "No. Rerun creates a new Workflow Node Run with a new Workflow Execution Session so each attempt can be traced independently."

### Local Profile and AI Usage

**Local Profile**:
The name and avatar stored on this device for the user's workspace.
_Avoid_: signed-in account, server identity

**AI Token Usage**:
The input, output, cache-read, cache-write, and reasoning tokens reported by
user-configured AI providers. Usage records describe local activity; they do
not represent a Reveric balance, subscription, or payment.
_Avoid_: credits, wallet balance, redemption

### Skill Marketplace

**Agent Skill**:
A reusable instruction set that an AI agent can discover and load for a
specific task. It is not a fictional skill, ability, or setting from a novel.
_Avoid_: Prompt, novel skill

**Private Agent Skill**:
An Agent Skill authored by one user and stored in that user's Skill Library.
It is never subject to marketplace review and is not automatically usable by
any novel.
_Avoid_: Globally enabled skill, unpublished marketplace skill

**Skill Library**:
A user's private, cross-novel collection of Private Agent Skills. It is
populated by direct creation or an explicit Save to Skill Library action. It is
a source catalog, not a set of instructions that agents can execute directly.
In V1 it is stored only on the user's current device.
_Avoid_: Global skill scope, installed skills

**Skill Marketplace**:
A reserved catalog entry point. The application shows a not-connected state;
publishing, review, and remote revocation have no active service contract.
_Avoid_: connected store, publication service, remote approval authority

**Marketplace Listing**:
A source identity represented by the reserved marketplace data model. Keeping
this identity does not imply that discovery or installation is connected.
_Avoid_: available catalog entry, published skill

**Marketplace Skill Version**:
A source version associated with an installed marketplace snapshot. Future
marketplace integration must define its own availability and review contract.
_Avoid_: current review workflow, active publication service

**Skill Import**:
The conversion of a Markdown file with supported skill frontmatter into a
structured skill draft. Imported files contain instruction text only; scripts,
archives, and arbitrary attachments are not skill content.
_Avoid_: Plugin upload, executable package

**Skill Category**:
A category string stored on a skill for browsing and filtering. It may be
selected from `skill_category` Dictionary Entries during creation, but it has
no persistent relationship to the dictionary.
_Avoid_: Dictionary foreign key, installation scope

**Skill Tag**:
A descriptive author-provided label assigned to a skill for browsing and
filtering in addition to its Skill Category. Skill tags are stored on the local device.
_Avoid_: Category, execution permission

**Dictionary Entry**:
A locally supplied category or tag suggestion. Suggestions help fill creation
forms; each skill persists its own category and tags.
_Avoid_: Dictionary foreign key, JSON configuration bag

**Installed Skill**:
A skill explicitly made usable by one novel. It may originate from a
Marketplace Listing, an Official Skill, or a Private Agent Skill; its content
is a snapshot that does not change when its source changes, including a newer
Marketplace Skill Version. It retains a stable source
identity and source version for explicit upgrades even if its local call name
changes.
_Avoid_: Global skill, marketplace listing

**Novel Installation**:
The relationship that grants one novel access to an Agent Skill. Each novel
has its own set of Installed Skills. In V1 it is stored only on the user's
current device and remains usable offline after installation.
_Avoid_: Global enablement, automatic availability

**Installation Collision**:
A same-call-name conflict when adding a skill to a novel. The user may replace
the existing Installed Skill or assign the new skill a distinct local call
name; renaming never breaks the new skill's source upgrade association.
_Avoid_: Name-based upgrade, silent replacement

**Skill Upgrade**:
An explicit per-novel action that replaces an Installed Skill's content
snapshot with a newer source version. It preserves the skill's local call
name, enabled state, and sort order.
_Avoid_: Automatic update, name-based update

**Bundled Control Skill**:
An app-shipped Agent Skill that is available to every novel without a Novel
Installation. V1 has exactly six: `setup`, `agent-rules`, `agent-skills`,
`skill-creator`, `subagents`, and `image` (call names: 创作向导 /
智能体规则管理 / 智能体技能管理 / 技能创作向导 / 子智能体管理 /
图像生成工具指南); they are not catalog entries, marketplace content, or
user-editable skills.
_Avoid_: Official Skill, default installed skill, bundled fallback

**Agent Skill Setup**:
The per-novel configuration flow for discovering and installing Official Skills,
Marketplace Listings, and Private Agent Skills. The marketplace portion shows a not-connected state. Local skill selection
and installation remain available without an account.
_Avoid_: Novel Onboarding, global skill setup, automatic installation

**Novel Onboarding**:
The chat-led process for establishing a new novel's writing constraints and
story foundations. The bundled `setup` control skill drives it by persisting
writing constraints as Agent Rules and story facts as workspace resources.
_Avoid_: Agent Skill Setup, migration dialog, one-shot questionnaire

**Setup Profile**:
A versioned branch of Novel Onboarding selected from the novel's type. It
defines the relevant question groups, story foundations, and skill
recommendations for that type; it is not a Marketplace Skill or persisted
skill installation.
_Avoid_: Genre skill, catalog category, fixed story template

**Novel Local Skill**:
An Agent Skill created directly inside one novel. It is usable only by that
novel and becomes a Private Agent Skill only when the user explicitly saves it
to the Skill Library.
_Avoid_: Installed skill, globally enabled skill

**Save to Skill Library**:
An explicit action that creates an independent Private Agent Skill copy from a
Novel Local Skill. It retains the original Novel Local Skill and does not
create automatic synchronization between the two copies.
_Avoid_: Move to library, linked copy

**Official Skill**:
An Agent Skill shipped with the app as a versioned local catalog entry.
Its content and references can be browsed and installed offline.
_Avoid_: Bundled skill, default skill, marketplace listing

**Official Skill Version**:
A revision of an Official Skill shipped with the app. It uses
the same source identity, installation snapshot, and explicit upgrade behavior
for locally installed snapshots.
_Avoid_: In-place system skill edit, automatic bundled update

## Screenplay Writing

**Work Content Kind**:
The immutable identity chosen when a Work is created: Novel or Screenplay. It
selects the content model and editor route and cannot be switched later, even
while the Work has no prose or screenplay elements.
_Avoid_: Editable work type, empty-work conversion

**Cross-Work Read Scope**:
The set of valid local works that an AI session may read through an explicit
`work_id`. It includes every valid local work, regardless of the current
screenplay's preferred adaptation source.
_Avoid_: Source-only permission, adaptation-source allowlist

**Source Novel**:
An optional Novel referenced by a screenplay adaptation as its original work.
It guides discovery and presentation but does not grant or restrict Cross-Work
Read Scope. It may be changed or cleared after creation without transforming
screenplay content. Deleting the Novel leaves the reference intact and
unavailable until that same Novel is restored. Fan-fiction source references
are not in the first release.
_Avoid_: Read permission, access allowlist, fan-fiction source

**Series Screenplay**:
A Screenplay Work representing an entire series and organized into one or more
Seasons, each containing Episodes. Characters, Locations, Relations, and story
reference material are shared across its Seasons.
_Avoid_: One Work per Season, film screenplay, single-episode film model

**Season**:
An ordered division of a Series Screenplay that owns its Episodes and its own
planned Episode count while sharing the Work's story assets. It is a first-class
domain entity rather than a prose rule or a separate Work.
_Avoid_: Season rule, Season Work, cross-Work Season link

**Current Season**:
The valid Season selected in the editor, remembered per Work in local workspace
state, and frozen as the default scope for one AI turn. Episode listing and
creation in the current Work may omit `season_id`; Beat and Scene operations
are already scoped by their Episode or stable resource ID. It is not screenplay
content and does not sync across devices. Only Season management and explicit
cross-Season operations name another Season.
_Avoid_: Latest Season, shared screenplay field, live-changing AI Season,
required Season path prefix

**Reference Work Season Scope**:
The Season resolution used when reading another Screenplay Work. A referenced
single-Season Work may omit `season_id` and resolves its only active Season; a
referenced multi-Season Work must provide `season_id`. It never inherits the
current editor Work's Current Season or guesses a first or latest Season.
_Avoid_: Cross-Work Current Season, guessed reference Season, shared Season ID

**Screenplay Workspace Selection**:
A versioned, device-local snapshot of the current Screenplay section, Season,
Episode, and Scene for one Work. Reopening restores valid IDs; invalid Season
selection falls back to the first active Season, then child selections reconcile
within that Season. Deleting the current Season selects the next Season at the
same list position, or the previous one when no next Season exists.
_Avoid_: Screenplay business data, cross-device reading progress, latest Season

**Single-Season Presentation**:
The default presentation of a Series Screenplay with exactly one active Season.
Season controls and terminology stay hidden while the sole Season remains the
implicit Current Season; adding a second Season reveals Season management.
_Avoid_: Seasonless Screenplay, optional Season record

**Required Season**:
The invariant that every active Series Screenplay owns at least one active
Season. Its last Season cannot be deleted, and creating a Season also creates
that Season's first Episode.
_Avoid_: Seasonless screenplay, empty Season

**Screenplay Format**:
The persisted rendering format of a Screenplay. It is intentionally retained
as a read-only field fixed to `asian` in the first release, while the UI exposes
no format label or selector.
_Avoid_: User-selectable first-release format, inferred format

**Act Group**:
A positive integer used to group Beats within one Episode. It is not a separate
entity and is not limited to a three-act structure.
_Avoid_: Act record, fixed three-act model

**AI-Proposed Scene**:
A Scene created by AI that remains subject to a scene-level creation review.
Rejecting the proposal removes the whole Scene rather than preserving an empty
Scene shell. A successful manual save inside the Scene accepts the proposal.
_Avoid_: Direct AI scene creation, orphaned empty scene

**Planned Episode Count**:
An optional target number of Episodes for one Season. It is guidance, not a
limit; more actual Episodes form a valid over-plan state.
_Avoid_: Episode cap, required episode total

**Screenplay Note**:
An editorial annotation attached to a Scene's element sequence. It is visible
while editing but excluded from the finished script and all screenplay metrics.
_Avoid_: Script action, counted screenplay content

**Scene Stage**:
The freely editable writing label of a Scene: draft or final. New and empty
Scenes are drafts; whether screenplay elements exist is not encoded as another
stage. Final denotes the currently accepted version, not a production lock,
and edits do not change it implicitly.
_Avoid_: Not started, Scene lock, production approval

**Scene Interior/Exterior**:
The optional Scene Heading classification that says whether a Scene occurs
indoors or outdoors. When unknown it is omitted from the heading; a transition
between the two is represented as two Scenes.
_Avoid_: Both, mixed interior/exterior Scene

**Scene Reference Protection**:
The rule that prevents deleting a Character or Location while an active Scene
still references it. It does not replace existing cleanup behavior for
non-Scene references or alter legacy novel deletion semantics.
_Avoid_: Global entity deletion lock, universal reference protection

**Required Episode**:
The invariant that every active Season owns at least one active Episode. The
last Episode of a Season cannot be deleted, even when other Seasons have
Episodes.
_Avoid_: Empty Season, screenplay-wide minimum Episode

**Cross-Season Episode Move**:
An explicit reassignment of an existing Episode to another active Season in
the same Screenplay. Omitting `episode_number` appends the Episode to the target
Season; providing it in the same write atomically inserts the Episode at that
target position. Both Seasons are renumbered, and all stable Episode and
child-resource IDs remain unchanged. Moving a source Season's only Episode is
rejected.
_Avoid_: Episode copy, implicit Current Season move, empty source Season,
cross-Work move

**Episode Number**:
The positive, contiguous display position of an Episode within its Season.
Reading `episode_number` returns that position; writing a valid position moves
the existing Episode within its current Season and transactionally shifts the
intervening Episodes. Stable references continue to use `episode_id`.
_Avoid_: Read-only Episode number, stable Episode identity, direct number patch

**Screenplay Character Reference**:
The stable `character_id` stored by a Character element to identify its
speaker. Character names are derived display data and are never accepted as
write references.
_Avoid_: Character name matching, alias-based speaker reference

**Scene Cast**:
The ordered set of Characters present in a Scene. It must include every
Character referenced by the Scene's dialogue elements and may additionally
include Characters who have no dialogue. Newly discovered speakers are appended
after the existing order, in order of first appearance. A referenced Character
cannot be removed until its dialogue blocks are removed or reassigned.
_Avoid_: Speaker-omitting cast, silently repaired cast write

**Dialogue Block**:
A Character element followed by its Parenthetical and Dialogue elements until
another element type ends the sequence. Deleting its Character cue alone never
deletes the dependent text implicitly.
_Avoid_: Cascading cue deletion, unowned dialogue

**Dialogue Cue Extension**:
Optional free text attached to a Character element to qualify performance or
sound source, such as `V.O.`, `CONT'D`, or a localized project-specific label.
It is trimmed but not enumerated and does not affect cast membership or metrics.
_Avoid_: Extension enum, dialogue classification

**AI Structural Deletion**:
An AI-initiated removal of an Episode, Scene, or Beat that commits immediately
as a soft deletion instead of entering text review. It follows the same cascade
and minimum-Episode rules as a user deletion. Season deletion is not included.
_Avoid_: Pending structural deletion, text-diff review, AI Season deletion

**User-Only Season Deletion**:
The boundary that permits deleting a Season only from an explicit Season
management interface after the user reviews its cascade and confirms. AI may
create and edit Seasons but cannot delete one, even after asking the user for
conversational confirmation.
_Avoid_: AI Season deletion, confirmation token, review-overlay Season removal

**User-Only Season Reordering**:
The boundary that permits reordering Seasons only from the explicit Season
management interface. AI may read, create, and edit Seasons, but
`season_number` remains read-only and no AI path accepts a replacement order.
_Avoid_: AI Season reorder, writable Season number, Season-order array

**Explicit Season Creation Intent**:
A current user task that clearly asks to add a Season, work on a next Season,
or plan a multi-Season structure. AI may create a Season only under this intent.
Exceeding the planned Episode count, story length, or AI structural preference
may justify a suggestion but never authorizes creation.
_Avoid_: Automatic Season split, over-plan Season creation, inferred consent,
confirmation boolean

**New Season Follow**:
The workspace transition after a Season and its initial Episode are created.
An open editor selects the new Season and Episode immediately, while an AI turn
keeps its pre-creation Current Season frozen; same-turn work in the new Season
therefore uses the IDs returned by Create.
_Avoid_: Stay on old Season, mutable turn scope, implicit same-turn retargeting

**Applied Working Change**:
An AI text change that is written to the current screenplay immediately while
its prior value is retained for review. Accepting confirms the current value;
rejecting restores the retained prior value.
_Avoid_: Deferred write, apply on accept

**Scene Body Review**:
The whole-Scene review of an AI-written elements array. The review card renders
only the latest proposed Scene body, without an old/new line diff or partial
line rollback. Accepting keeps the whole array and rejecting restores the whole
prior array; Synopsis review remains ordinary text review.
_Avoid_: Scene-body line review, JSON diff, rendered-text rollback

**AI Scene Creation**:
One Create operation that writes a Scene's structure, Synopsis, and initial
Elements and records only one Scene-level create change containing their
preview. Rejecting that create change deletes the Scene; edits made after
creation remain ordinary field changes, matching current Chapter behavior.
_Avoid_: Split initial field changes, Scene proposal aggregate

**Superseding Manual Save**:
A successful debounced save of any user edit inside a Scene with active AI
changes. Without an extra confirmation, it first accepts all active AI changes
for that Scene, including its creation proposal, and then records the user's
edit, so later rejection cannot restore an older snapshot or delete the user's
work. Focus alone and failed saves do not supersede anything.
_Avoid_: Parallel manual and AI review states, three-way merge
