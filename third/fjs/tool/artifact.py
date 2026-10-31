#!/usr/bin/env python3
"""Bind ignored FJS archives to source, targets and installed build tools."""
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[3]
BINARIES = ROOT / 'third/fjs/darwin/fjs/Binaries'
ARCHIVE = BINARIES / 'fjs.xcframework.zip'
RECORD = BINARIES / 'reveric-build.json'
RUST = '1.97.1'
TARGETS = ['aarch64-apple-ios', 'aarch64-apple-ios-sim',
           'aarch64-apple-darwin']


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def identity():
    paths = {name for name in run('git', 'ls-files', '--cached', '--others',
                                 '--exclude-standard', 'third/fjs').splitlines()
             if (ROOT / name).is_file()}
    paths.add('cargokit_options.yaml')
    inputs = {name: digest(ROOT / name) for name in sorted(paths)}
    # Flutter only hosts the CargoKit build tool; dart-sys ships its own Dart API
    # headers, so the SDK revision does not reach the native archive.
    tools = {'rust': run('rustc', '+' + RUST, '-Vv'),
             'host': platform.system(), 'architecture': platform.machine(), 'targets': TARGETS}
    if platform.system() == 'Darwin':
        tools.update(xcode=run('xcodebuild', '-version'),
                     iphoneos=run('xcrun', '--sdk', 'iphoneos', '--show-sdk-version'),
                     macosx=run('xcrun', '--sdk', 'macosx', '--show-sdk-version'))
    value = {'inputs': inputs, 'toolchain': tools}
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest(), value


def verify(key):
    if not RECORD.is_file() or not ARCHIVE.is_file():
        return False
    record = json.loads(RECORD.read_text())
    checksum = ARCHIVE.with_suffix('.zip.checksum').read_text().strip()
    return record['key'] == key and record['archive_sha256'] == digest(ARCHIVE) == checksum


def binary_uuids(binary):
    return {tuple(line.split()[1:3]) for line in run('dwarfdump', '--uuid', str(binary)).splitlines()}


def prepare_swiftpm(reference):
    """Invalidate only stale FJS generated outputs, never copy binaries into apps."""
    artifact = ROOT / 'build/macos/SourcePackages/artifacts/fjs'
    cached = artifact / 'FjsBinary/fjs.xcframework/macos-arm64/fjs.framework/Versions/A/fjs'
    products = ROOT / 'build/macos/Build/Products'
    if artifact.exists() and (not cached.is_file() or binary_uuids(cached) != reference):
        if artifact.is_symlink():
            raise SystemExit('Refusing to remove symlinked SwiftPM artifact')
        shutil.rmtree(artifact)
        for configuration in ('Debug', 'Profile', 'Release'):
            framework = products / configuration / 'fjs.framework'
            if framework.is_symlink():
                raise SystemExit('Refusing to remove symlinked generated FJS framework')
            if framework.exists():
                shutil.rmtree(framework)
        print('Invalidated stale generated SwiftPM FJS artifact and framework products')
    # Xcode Copy's directory signature can miss replaced contents whose zip
    # timestamps stay fixed. Missing declared outputs reliably rerun that task.
    for configuration in ('Debug', 'Profile', 'Release'):
        for embedded in (products / configuration).glob('*.app/Contents/Frameworks/fjs.framework/fjs'):
            if binary_uuids(embedded) != reference:
                framework = embedded.parent
                if framework.is_symlink():
                    raise SystemExit('Refusing to remove symlinked embedded FJS framework')
                shutil.rmtree(framework)
                print('Invalidated stale generated embedded FJS: ' + str(framework))


def archive_uuids():
    with tempfile.TemporaryDirectory(prefix='fjs-artifact-reference-') as temporary:
        with zipfile.ZipFile(ARCHIVE) as archive:
            member = next(n for n in archive.namelist() if n.endswith('macos-arm64/fjs.framework/Versions/A/fjs'))
            reference = archive.extract(member, temporary)
        result = binary_uuids(reference)
        if not result:
            raise SystemExit('FJS archive contains no macOS UUID')
        return result


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else 'key'
    key, value = identity()
    if command == 'key':
        print('fjs-' + key)
    elif command == 'verify':
        if not verify(key):
            raise SystemExit('FJS archive missing or source/toolchain/checksum mismatch')
        print('Verified patched archive: ' + digest(ARCHIVE))
    elif command == 'prepare-swiftpm':
        if not verify(key):
            raise SystemExit('Verify/build archive before preparing SwiftPM')
        prepare_swiftpm(archive_uuids())
    elif command == 'record':
        if len(sys.argv) != 3 or sys.argv[2] != 'fjs-' + key:
            raise SystemExit('Source/toolchain changed during native build; rebuild before recording')
        checksum = ARCHIVE.with_suffix('.zip.checksum').read_text().strip()
        if digest(ARCHIVE) != checksum:
            raise SystemExit('FJS generation checksum mismatch')
        generation = ROOT / 'third/fjs/build/darwin-xcframework/generation/manifest.json'
        # CargoKit writes its own recipe/assets manifest alongside the generation.
        candidates = list(generation.parent.glob('*.json'))
        manifest = next((p for p in candidates if json.loads(p.read_text()).get('scope') == 'cargokit-local-precompiled-generation'), None)
        if manifest is None:
            raise SystemExit('CargoKit generation provenance missing')
        provenance = json.loads(manifest.read_text())
        if provenance['recipe']['rust_toolchain'] != RUST:
            raise SystemExit('CargoKit generation used a different Rust toolchain')
        asset = next(a for a in provenance['assets'] if a['name'] == ARCHIVE.name)
        if asset['sha256'] != checksum:
            raise SystemExit('Archive differs from local generation')
        RECORD.write_text(json.dumps({'key': key, 'archive_sha256': checksum,
                                      'source': value, 'generation': provenance}, indent=2) + '\n')
        print('Recorded patched archive: ' + checksum)
    elif command == 'verify-app':
        if not verify(key):
            raise SystemExit('Verify/build archive before checking app')
        app = Path(sys.argv[2])
        binary = app / 'Contents/Frameworks/fjs.framework/fjs'
        with tempfile.TemporaryDirectory(prefix='codemode-artifact-') as temporary:
            with zipfile.ZipFile(ARCHIVE) as archive:
                member = next(n for n in archive.namelist() if n.endswith('macos-arm64/fjs.framework/Versions/A/fjs'))
                reference = archive.extract(member, temporary)
            def uuids(path):
                return {tuple(line.split()[1:3]) for line in run('dwarfdump', '--uuid', str(path)).splitlines()}
            if not uuids(binary) or not uuids(binary).issubset(uuids(reference)):
                raise SystemExit('Packaged FJS UUIDs differ from patched source archive')
        print('Packaged FJS UUIDs match patched archive: ' + str(binary))
    else:
        raise SystemExit('usage: artifact.py key|verify|record|verify-app APP')


if __name__ == '__main__':
    main()
