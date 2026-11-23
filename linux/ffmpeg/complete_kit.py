#!/usr/bin/env python3
"""Assemble a self-contained FFmpegKit Linux bundle.

The published full-gpl archive ships libffmpegkit and libav* only. Those
libraries link Ubuntu 22.04 sonames and have no RUNPATH, so a clean machine
cannot dlopen them. This downloads that archive, copies the missing shared
libraries from the Ubuntu 22.04 archive, and sets every bundled library's
RUNPATH to $ORIGIN.

libc, libm, the C++ runtime, zlib, and the GLib/GTK libraries already required
to launch the Flutter app stay on the system.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import os
import shutil
import stat
import struct
import subprocess
import tarfile
import tempfile
import urllib.request
from pathlib import Path

ARCHIVE_NAME = "ffmpeg-kit-linux-x86_64-full-gpl-8.1.2.tar.gz"
ARCHIVE_URL = (
    "https://github.com/sk3llo/ffmpeg_kit_flutter/releases/download/"
    f"8.1.2-full-gpl/{ARCHIVE_NAME}"
)
ARCHIVE_SHA256 = (
    "1e64357ee5effd3a69334acdd7655fb648607898f65ac6b851ee8acb46f5815d"
)
SCRIPT_REVISION = "4"
UBUNTU = "https://archive.ubuntu.com/ubuntu"
DIST_ORDER = ("jammy", "jammy-updates", "jammy-security")
PACKAGE_COMPONENTS = ("main", "universe", "multiverse")

# Sonames the Flutter GTK app already loads, or that must stay the system copy.
SYSTEM_SONAMES = frozenset(
    {
        "libc.so.6",
        "libm.so.6",
        "libdl.so.2",
        "libpthread.so.0",
        "librt.so.1",
        "libresolv.so.2",
        "ld-linux-x86-64.so.2",
        "libgcc_s.so.1",
        "libstdc++.so.6",
        "libz.so.1",
        "libglib-2.0.so.0",
        "libgobject-2.0.so.0",
        "libgio-2.0.so.0",
        "libgmodule-2.0.so.0",
        "libgtk-3.so.0",
        "libgdk-3.so.0",
        "libcairo.so.2",
        "libpango-1.0.so.0",
        "libpangocairo-1.0.so.0",
        "libgdk_pixbuf-2.0.so.0",
        # libass pulls this in through the jammy archive. Bundling jammy's 2.7.4
        # shadows the newer system build that Pango 1.52 requires, so keep the
        # soname on the system like the rest of the GTK stack.
        "libharfbuzz.so.0",
    }
)

# The plugin wrapper links this. It is not a dependency of libav*.
EXTRA_SONAMES = ("libjson-glib-1.0.so.0",)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--cache", required=True, type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    cache = args.cache.resolve()
    stamp = output / ".complete_kit_stamp"
    want = f"{SCRIPT_REVISION} {ARCHIVE_SHA256}"
    if stamp.is_file() and stamp.read_text(encoding="utf-8").strip() == want:
        if (output / "lib" / "libffmpegkit.so").exists():
            print(f"FFmpegKit Linux bundle is ready at {output}")
            return
    cache.mkdir(parents=True, exist_ok=True)
    archive = _cached_archive(cache)
    lib_dir = output / "lib"
    if lib_dir.exists():
        shutil.rmtree(lib_dir)
    lib_dir.mkdir(parents=True)
    notices = _extract_ffmpeg(archive, lib_dir)
    indexes = _ubuntu_indexes(cache)
    pending = list(_needed(lib_dir))
    pending.extend(EXTRA_SONAMES)
    seen: set[str] = set()
    while pending:
        soname = pending.pop()
        if soname in seen or soname in SYSTEM_SONAMES:
            continue
        seen.add(soname)
        if (lib_dir / soname).exists():
            pending.extend(_needed_of(lib_dir / soname))
            continue
        package = indexes.package_for(soname)
        deb = indexes.fetch(package, cache / "debs")
        _install_soname(deb, soname, lib_dir)
        pending.extend(_needed_of(lib_dir / soname))
        if len(seen) > 200:
            raise SystemExit("dependency closure exceeded 200 libraries")
    _set_runpath(lib_dir)
    missing = _external_needed(lib_dir)
    if missing:
        raise SystemExit("bundle still needs: " + ", ".join(sorted(missing)))
    _write_notices(output, notices)
    stamp.write_text(want + "\n", encoding="utf-8")
    total = sum(path.lstat().st_size for path in lib_dir.iterdir() if not path.is_symlink())
    print(
        f"FFmpegKit Linux bundle is ready at {output} "
        f"({len(list(lib_dir.iterdir()))} files, {total / (1024 * 1024):.1f} MiB)"
    )


def _cached_archive(cache: Path) -> Path:
    path = cache / ARCHIVE_NAME
    if not path.is_file() or _sha256(path) != ARCHIVE_SHA256:
        print(f"Downloading {ARCHIVE_NAME}")
        _download(ARCHIVE_URL, path)
    digest = _sha256(path)
    if digest != ARCHIVE_SHA256:
        raise SystemExit(f"{path}: sha256 {digest} != {ARCHIVE_SHA256}")
    return path


def _extract_ffmpeg(archive: Path, lib_dir: Path) -> dict[str, bytes]:
    notices: dict[str, bytes] = {}
    with tarfile.open(archive, "r:gz") as bundle:
        members = [item for item in bundle.getmembers() if "/lib/" in f"/{item.name}"]
        if not members:
            raise SystemExit(f"{archive} has no lib/ directory")
        for item in members:
            name = Path(item.name).name
            if not name or name in {".", ".."} or not (item.isfile() or item.issym()):
                continue
            if item.issym():
                if ".so" not in name:
                    continue
                (lib_dir / name).symlink_to(item.linkname)
                continue
            source = bundle.extractfile(item)
            if source is None:
                raise SystemExit(f"{archive} missing {item.name}")
            payload = source.read()
            if name.startswith("license") or name == "source.txt":
                notices[name] = payload
                continue
            if ".so" not in name:
                continue
            target = lib_dir / name
            target.write_bytes(payload)
            target.chmod(0o755)
    return notices


class _Indexes:
    def __init__(self, packages: dict[str, str], records: dict[str, tuple[str, str]]):
        self._packages = packages
        self._records = records

    def package_for(self, soname: str) -> str:
        package = self._packages.get(soname)
        if package is None:
            raise SystemExit(f"Ubuntu 22.04 has no package for {soname}")
        return package

    def fetch(self, package: str, deb_dir: Path) -> Path:
        filename, digest = self._records[package]
        deb_dir.mkdir(parents=True, exist_ok=True)
        path = deb_dir / Path(filename).name
        if not path.is_file() or _sha256(path) != digest:
            print(f"Downloading {package}")
            _download(f"{UBUNTU}/{filename}", path)
        actual = _sha256(path)
        if actual != digest:
            raise SystemExit(f"{path}: sha256 {actual} != {digest}")
        return path


def _ubuntu_indexes(cache: Path) -> _Indexes:
    # jammy-updates and jammy-security republish the whole file list and are
    # hundreds of megabytes. The release list already maps each soname to its
    # package; the newer debs are selected from the package indexes below.
    packages: dict[str, str] = {}
    contents = _cached_download(
        cache,
        "Contents-jammy-amd64.gz",
        f"{UBUNTU}/dists/jammy/Contents-amd64.gz",
    )
    with gzip.open(contents, "rt", encoding="utf-8", errors="replace") as index:
        for line in index:
            parts = line.split()
            if len(parts) < 2 or "/" not in parts[0]:
                continue
            path, base = parts[0].rsplit("/", 1)
            if path not in {
                "usr/lib/x86_64-linux-gnu",
                "lib/x86_64-linux-gnu",
            }:
                continue
            packages[base] = parts[-1].rsplit("/", 1)[-1]
    records: dict[str, tuple[str, str]] = {}
    for dist in DIST_ORDER:
        for component in PACKAGE_COMPONENTS:
            text = gzip.open(
                _cached_download(
                    cache,
                    f"Packages-{dist}-{component}-amd64.gz",
                    f"{UBUNTU}/dists/{dist}/{component}/binary-amd64/Packages.gz",
                ),
                "rt",
                encoding="utf-8",
                errors="replace",
            ).read()
            for record in text.split("\n\n"):
                fields = _control_fields(record)
                name = fields.get("Package")
                filename = fields.get("Filename")
                digest = fields.get("SHA256")
                if name and filename and digest:
                    records[name] = (filename, digest)
    return _Indexes(packages, records)


def _control_fields(record: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    current = ""
    for line in record.splitlines():
        if not line:
            continue
        if line.startswith(" ") or line.startswith("\t"):
            if current:
                fields[current] += " " + line.strip()
            continue
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        current = key
        fields[current] = value.strip()
    return fields


def _cached_download(cache: Path, name: str, url: str) -> Path:
    path = cache / name
    if not path.is_file():
        print(f"Downloading {name}")
        _download(url, path)
    return path


def _install_soname(deb: Path, soname: str, lib_dir: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="reveric-deb-") as temporary:
        root = Path(temporary)
        _extract_deb(deb, root)
        match = next(
            (path for path in root.rglob(soname) if path.is_symlink() or path.is_file()),
            None,
        )
        if match is None:
            raise SystemExit(f"{deb.name} does not contain {soname}")
        resolved = match.resolve()
        target = lib_dir / soname
        shutil.copyfile(resolved, target)
        target.chmod(0o755)


def _extract_deb(deb: Path, root: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="reveric-ar-") as temporary:
        staging = Path(temporary)
        subprocess.run(["ar", "-x", str(deb)], cwd=staging, check=True)
        data = next(staging.glob("data.tar.*"))
        if data.name.endswith(".zst"):
            unpacked = staging / "data.tar"
            subprocess.run(
                ["zstd", "-q", "-d", "-f", str(data), "-o", str(unpacked)],
                check=True,
            )
            data = unpacked
        with tarfile.open(data, "r:*") as archive:
            if hasattr(tarfile, "data_filter"):
                archive.extractall(root, filter="data")
            else:
                archive.extractall(root)


def _set_runpath(lib_dir: Path) -> None:
    patched: set[Path] = set()
    for path in sorted(lib_dir.iterdir()):
        if not path.is_file() or path.is_symlink():
            continue
        real = path.resolve()
        if real in patched or not _is_elf(real):
            continue
        subprocess.run(
            ["patchelf", "--set-rpath", r"$ORIGIN", str(real)],
            check=True,
        )
        patched.add(real)


def _needed(lib_dir: Path) -> set[str]:
    found: set[str] = set()
    for path in lib_dir.iterdir():
        if path.is_file() and not path.is_symlink() and _is_elf(path):
            found.update(_needed_of(path))
    return found


def _external_needed(lib_dir: Path) -> set[str]:
    present = {path.name for path in lib_dir.iterdir()}
    return {
        name
        for name in _needed(lib_dir)
        if name not in present and name not in SYSTEM_SONAMES
    }


def _needed_of(path: Path) -> list[str]:
    data = path.read_bytes()
    if not _is_elf_bytes(data):
        return []
    endian = "<" if data[5] == 1 else ">"
    section_offset = struct.unpack_from(endian + "Q", data, 40)[0]
    section_size = struct.unpack_from(endian + "H", data, 58)[0]
    section_count = struct.unpack_from(endian + "H", data, 60)[0]
    sections = []
    for index in range(section_count):
        offset = section_offset + index * section_size
        unpacked = struct.unpack_from(endian + "IIQQQQIIQQ", data, offset)
        sections.append(unpacked)
    dynamic = next(section for section in sections if section[1] == 6)
    string_table = sections[dynamic[6]]
    names: list[str] = []
    cursor = dynamic[4]
    entry_size = dynamic[9] or 16
    end = cursor + dynamic[5]
    while cursor < end:
        tag, value = struct.unpack_from(endian + "qQ", data, cursor)
        if tag == 0:
            break
        if tag == 1:
            start = string_table[4] + value
            stop = data.index(b"\x00", start)
            names.append(data[start:stop].decode())
        cursor += entry_size
    return names


def _is_elf(path: Path) -> bool:
    try:
        return _is_elf_bytes(path.read_bytes()[:4])
    except OSError:
        return False


def _is_elf_bytes(data: bytes) -> bool:
    return data[:4] == b"\x7fELF"


def _write_notices(output: Path, upstream: dict[str, bytes]) -> None:
    licenses = Path(__file__).resolve().parent / "licenses"
    destination = output / "LICENSES"
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir()
    for notice in sorted(licenses.iterdir()):
        if notice.is_file():
            shutil.copyfile(notice, destination / notice.name)
    for name, payload in sorted(upstream.items()):
        written = "ffmpeg-kit-source.txt" if name == "source.txt" else name
        (destination / written).write_bytes(payload)
    (destination / "SOURCE").write_text(
        "\n".join(
            [
                "FFmpegKit 8.1.2 full-gpl shared libraries for Linux x86_64,",
                "plus the Ubuntu 22.04 libraries those binaries link.",
                f"Archive: {ARCHIVE_NAME}",
                f"Release: {ARCHIVE_URL}",
                f"SHA256: {ARCHIVE_SHA256}",
                "The FFmpeg build targets glibc 2.35 or newer.",
                "",
            ]
        ),
        encoding="utf-8",
    )


def _download(url: str, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".part")
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "reveric-ffmpeg-bundle"},
    )
    with urllib.request.urlopen(request, timeout=120) as response, temporary.open("wb") as output:
        shutil.copyfileobj(response, output)
    os.chmod(temporary, stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH)
    temporary.replace(path)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


if __name__ == "__main__":
    main()
