"""Build the R2 update manifest from the assets of a packaged GitHub release."""

import json
import sys
from pathlib import Path


def main(tag, work_dir):
    release = json.loads((work_dir / "release.json").read_text(encoding="utf-8"))
    if release["tag_name"] != tag:
        raise SystemExit(f"Expected release {tag}, got {release['tag_name']}")
    if release["draft"] or release["prerelease"]:
        print(f"Skipping update manifest for draft or prerelease {tag}")
        return

    version = tag.removeprefix("v")
    current_path = work_dir / "current.json"
    if current_path.exists():
        current = json.loads(current_path.read_text(encoding="utf-8"))["version"]
        if tuple(map(int, current.split("."))) > tuple(map(int, version.split("."))):
            print(f"Keeping newer update manifest for v{current}")
            return

    packages = {
        "macos-arm64": f"reveric-{version}-macos-arm64.zip",
        "windows": f"reveric-{version}-windows-setup.exe",
        "linux": f"reveric-{version}-linux.zip",
        "android": f"reveric-android-arm64-v8a-v{version}.apk",
    }
    assets = {asset["name"]: asset for asset in release["assets"]}
    platforms = {}
    for platform, name in packages.items():
        asset = assets.get(name)
        if not asset or asset["state"] != "uploaded" or asset["size"] <= 0:
            raise SystemExit(f"Release {tag} is missing the completed update package {name}")
        platforms[platform] = {
            "download_url": f"https://downloads.reveric.app/releases/{tag}/{name}",
            "fallback_download_url": asset["browser_download_url"],
            "file_size": asset["size"],
        }

    manifest = {
        "version": version,
        "release_notes": release["body"],
        "platforms": platforms,
    }
    (work_dir / "latest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main(sys.argv[1], Path(sys.argv[2]))
