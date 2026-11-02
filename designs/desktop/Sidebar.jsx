// Home sidebar — mirrors lib/desktop/pages/home.dart _buildSidebar().
// The desktop home uses one navigation column: search, Works, AI entries,
// recent sessions, then Settings. Editor-only rails stay in EditorView.
// Footer: community links (QQ group + GitHub) above the local profile bar.

function SectionGroupHeader({ children }) {
  return <div className="m-sb-group-header">{children}</div>;
}

function LeafItem({ icon, title, active, onClick }) {
  return (
    <button
      type="button"
      className={"m-sb-nav" + (active ? " is-selected" : "")}
      onClick={onClick}
    >
      <Icon name={icon} size={16} className="m-sb-nav__icon" />
      <span className="m-sb-nav__title">{title}</span>
      <Icon name="caret-right" size={16} className="m-sb-nav__go" />
    </button>
  );
}

function RecentSessions({ sessions }) {
  const [expanded, setExpanded] = React.useState(true);
  if (!sessions.length) return null;

  return (
    <div className="m-sb-recent">
      <button
        type="button"
        className="m-sb-row m-sb-row--header"
        onClick={() => setExpanded((value) => !value)}
      >
        <Icon name="chat-centered" size={16} />
        <span className="m-sb-row__title">最近对话</span>
        <span className="m-sb-row__spacer" />
        <Icon
          name="caret-right"
          size={14}
          style={{ transform: `rotate(${expanded ? 90 : 0}deg)`, opacity: 0.6 }}
        />
      </button>
      {expanded && (
        <div className="m-sb-section m-sb-section--padded">
          {sessions.map((session) => (
            <button key={session.id} type="button" className="m-sb-session">
              <Icon name="chat-centered" size={14} style={{ opacity: 0.55 }} />
              <div className="m-sb-leaf__meta">
                <span className="m-sb-leaf__title">{session.title}</span>
                <span className="m-sb-session__time">{session.time}</span>
              </div>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

const QQ_GROUP_NUMBER = "924148054";
// 与 lib/shared/app_config.dart revericQqGroupJoinUrl / revericGitHubRepoUrl 一致。
const QQ_GROUP_JOIN_URL = "https://qm.qq.com/q/Ap8pfOWHDO";
const GITHUB_REPO_URL = "https://github.com/looplj/reveric";

// QQ 群是主入口：带文字，比纯图标更容易被看到；群号只提供复制。GitHub 退为图标按钮。
function CommunityRow() {
  const [copied, setCopied] = React.useState(false);
  const copy = () => {
    navigator.clipboard?.writeText(QQ_GROUP_NUMBER);
    setCopied(true);
    setTimeout(() => setCopied(false), 1400);
  };

  return (
    <div className="m-sb-community">
      <div className="m-sb-qq">
        <button
          type="button"
          className="m-sb-qq__open"
          title="打开 QQ 加入交流群"
          onClick={() => window.open(QQ_GROUP_JOIN_URL, "_blank")}
        >
          <span className="m-sb-qq__mark"><QqMark size={14} /></span>
          <span className="m-sb-qq__label">加入 QQ 群</span>
        </button>
        <button
          type="button"
          className="m-sb-qq__copy"
          title={copied ? "已复制到剪贴板" : "复制"}
          onClick={copy}
        >
          <Icon name={copied ? "check" : "copy"} size={14} />
        </button>
      </div>
      <button
        type="button"
        className="m-icon-btn"
        title="GitHub 开源仓库"
        onClick={() => window.open(GITHUB_REPO_URL, "_blank")}
      >
        <Icon name="github-logo" size={16} />
      </button>
    </div>
  );
}

function ProfileBar({ name }) {
  return (
    <button type="button" className="m-sb-profile">
      <DefaultAvatar name={name} size={32} />
      <span className="m-sb-profile__name">{name}</span>
      <Icon name="caret-right" size={16} className="m-sb-profile__go" />
    </button>
  );
}

function Sidebar({ activeContent, onSelect, onOpenSettings }) {
  const sessions = window.REVERIC_DATA.recentSessions;

  return (
    <aside className="m-sidebar">
      {/* 作品搜索挪到了书库作品区那一行（只搜当前集合），侧栏不再放。 */}
      <div className="m-sidebar__scroll">
        <SectionGroupHeader>创作</SectionGroupHeader>
        {/* 小说和剧本合在一个作品库里：类型是作品的属性，在作品区按类型筛选，
            不再各占一个入口。 */}
        <LeafItem
          icon="books"
          title="作品"
          active={activeContent === "library"}
          onClick={() => onSelect("library")}
        />

        <SectionGroupHeader>AI</SectionGroupHeader>
        <LeafItem
          icon="sliders-horizontal"
          title="模型设置"
          active={activeContent === "modelSettings"}
          onClick={() => onSelect("modelSettings")}
        />
        <LeafItem
          icon="sparkle"
          title="智能体技能"
          active={activeContent === "skillLibrary" || activeContent === "skillList" || activeContent === "skill"}
          onClick={() => onSelect("skillLibrary")}
        />
        <LeafItem
          icon="users-three"
          title="专家团"
          active={activeContent === "expertTeam" || activeContent === "subagent"}
          onClick={() => onSelect("expertTeam")}
        />
        <LeafItem
          icon="paper-plane-tilt"
          title="快捷方式"
          active={activeContent === "shortcutList" || activeContent === "shortcut"}
          onClick={() => onSelect("shortcutList")}
        />

        <RecentSessions sessions={sessions} />

        <SectionGroupHeader>设置</SectionGroupHeader>
        <LeafItem icon="gear-six" title="设置" onClick={onOpenSettings} />
      </div>
      <div className="m-sb-foot">
        <CommunityRow />
        <ProfileBar name="远山行者" />
      </div>
    </aside>
  );
}

Object.assign(window, { Sidebar });
