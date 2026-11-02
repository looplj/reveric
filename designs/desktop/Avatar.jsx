// Default user avatar — mirrors lib/shared/widgets/user_avatar.dart (same hash and
// tones as RevericColors.avatarTones). Shown only when no avatar image is set.
//
// Variants (switch with ?avatar=… for review):
//   mono   (default) — first glyph of the nickname on a tone picked from the name
//   ink               — two-layer mountain silhouette, tone picked from the name
//   legacy            — current grey person icon, kept for comparison
//
// Tones are fixed muted hues (青 黛 赭 藕 苍): the Reveric palette is mostly
// ink-green, so semantic tokens alone would give near-identical avatars.
// Backgrounds mix the tone into --surface, so light and dark both stay calm.
const AVATAR_TONES = ["#4F8C7C", "#56688C", "#A7714F", "#93708A", "#76875A"];

function avatarHash(name) {
  let h = 0;
  for (const ch of name) h = (h * 31 + ch.codePointAt(0)) & 0x7fffffff;
  return h;
}

function avatarGlyph(name) {
  const first = Array.from(name.trim())[0] || "R";
  return /[a-z]/i.test(first) ? first.toUpperCase() : first;
}

const AVATAR_VARIANT =
  new URLSearchParams(location.search).get("avatar") || "mono";

function DefaultAvatar({ name = "Reveric", size = 32, variant = AVATAR_VARIANT }) {
  const seed = avatarHash(name || "Reveric");
  const tone = AVATAR_TONES[seed % AVATAR_TONES.length];
  const base = { width: size, height: size };

  if (variant === "legacy") {
    return (
      <span className="m-uavatar m-uavatar--legacy" style={base}>
        <Icon name="user" size={Math.round(size * 0.5)} />
      </span>
    );
  }

  if (variant === "ink") {
    // Peaks shift with the seed so neighbours rarely look identical.
    const a = 30 + (seed % 18);
    const b = 58 + ((seed >> 5) % 20);
    return (
      <span
        className="m-uavatar m-uavatar--ink"
        style={{ ...base, "--tone": tone }}
      >
        <svg viewBox="0 0 100 100" width="100%" height="100%" aria-hidden="true">
          <circle cx={72 - (seed % 14)} cy="30" r="9" className="m-uavatar__sun" />
          <path
            d={`M0 74 L${a} 46 L${a + 16} 60 L${b} 38 L100 66 L100 100 L0 100Z`}
            className="m-uavatar__far"
          />
          <path
            d={`M0 86 L${a + 10} 64 L${b - 4} 80 L${b + 14} 68 L100 84 L100 100 L0 100Z`}
            className="m-uavatar__near"
          />
        </svg>
      </span>
    );
  }

  return (
    <span
      className="m-uavatar m-uavatar--mono"
      style={{ ...base, "--tone": tone, fontSize: Math.round(size * 0.44) }}
    >
      {avatarGlyph(name)}
    </span>
  );
}

// QQ brand mark (Simple Icons, CC0). Solid, inherits currentColor.
function QqMark({ size = 16 }) {
  return (
    <svg viewBox="0 0 24 24" width={size} height={size} fill="currentColor" aria-hidden="true">
      <path d="M21.395 15.035a40 40 0 0 0-.803-2.264l-1.079-2.695c.001-.032.014-.562.014-.836C19.526 4.632 17.351 0 12 0S4.474 4.632 4.474 9.241c0 .274.013.804.014.836l-1.08 2.695a39 39 0 0 0-.802 2.264c-1.021 3.283-.69 4.643-.438 4.673.54.065 2.103-2.472 2.103-2.472 0 1.469.756 3.387 2.394 4.771-.612.188-1.363.479-1.845.835-.434.32-.379.646-.301.778.343.578 5.883.369 7.482.189 1.6.18 7.14.389 7.483-.189.078-.132.132-.458-.301-.778-.483-.356-1.233-.646-1.846-.836 1.637-1.384 2.393-3.302 2.393-4.771 0 0 1.563 2.537 2.103 2.472.251-.03.581-1.39-.438-4.673" />
    </svg>
  );
}

Object.assign(window, { DefaultAvatar, QqMark });
