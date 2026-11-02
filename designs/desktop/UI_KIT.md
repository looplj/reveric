# Reveric Desktop — UI Kit

Pixel-fidelity recreation of the Reveric desktop client in HTML + React
(via Babel-in-browser). Built from this repository’s Flutter source:

- Theme: `lib/shared/theme/` (colors, typography, spacing, icons)
- Home page: `lib/desktop/pages/home.dart`
- Novel editor: `lib/desktop/pages/novel_editor.dart`
- Sidebar: `lib/desktop/widgets/sidebar/`
- Chat panel: `lib/desktop/widgets/ai/chat/`

## Screens included

1. **Home / Library** — left sidebar (search + Works/AI/Settings sections
   with collapsible tags, agents, subagents, skills), novel grid main
   panel, right rail with AI quick‑chat.
2. **Novel Editor** — chapter tree on the left, manuscript editor in the
   middle (Georgia 16px/1.75, 72px gutters), AI chat panel docked right.
3. **Settings dialog** — provider list + appearance switcher.

Click around: the Library opens a novel into the editor; the editor's
back button returns to the library.

## Components

| File                    | Role                                                |
|-------------------------|-----------------------------------------------------|
| `index.html`            | Mounts the app, wires CSS and Babel scripts        |
| `App.jsx`               | Top‑level routing (library ↔ editor)                |
| `Icon.jsx`              | Phosphor SVG renderer (mask‑recolor pattern)       |
| `Avatar.jsx`            | Default user avatar (name monogram) + QQ brand mark |
| `WindowFrame.jsx`       | Desktop traffic‑lights + window padding             |
| `Sidebar.jsx`           | Left rail: sections, community row (QQ / GitHub), profile bar |
| `LibraryView.jsx`       | Works home: continue-writing hero + mixed shelf     |
| `NovelCard.jsx`         | Individual novel card with cover                    |
| `EditorView.jsx`        | Chapter tree + manuscript editor frame              |
| `ChapterTree.jsx`       | Volume / chapter / outline navigator                |
| `ManuscriptEditor.jsx`  | Title + Georgia manuscript with toolbar             |
| `ChatPanel.jsx`         | AI conversation surface with composer               |
| `SettingsDialog.jsx`    | Modal for provider + appearance settings            |
| `data.js`               | Mock novels, chapters, chat history                |

## Conventions

- All colors come from CSS variables in `colors_and_type.css` —
  never hard‑code hex.
- All icons are phosphor SVG mounted via `<Icon name="..." size={16} />`.
  Add a new icon by dropping its SVG into `assets/icons/phosphor/`
  and using its filename minus `.svg`.
- Hover/selected/focus colors are token‑driven (`--hover`, `--selected`,
  `--accent`).
- Cards and panels float: `--card-border` + `--shadow-card` +
  `--radius-2xl` on `surface`. Chrome (sidebars, toolbars, inputs, list
  rows) stays flat. Titles use `--font-display` (sans); Georgia is only
  for manuscript prose.
