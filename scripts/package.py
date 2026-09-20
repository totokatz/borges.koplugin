"""Build and verify the installable KOReader archive. Python standard library only."""
import argparse
import hashlib
from pathlib import Path, PurePosixPath
import re
import stat
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = "highlightsdetoto.koplugin"
REQUIRED = {"main.lua", "_meta.lua", "plugin_version.lua", "updater.lua"}
PRIVATE = {"web_config.json", "dropbox_config.json"}


def release_files(source):
    files = []
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        if any(p.startswith(".") or p == "spec" for p in relative.parts):
            continue
        if path.name in PRIVATE:
            continue
        if path.is_symlink():
            raise ValueError(f"Symlink in package: {relative}")
        if path.is_file():
            files.append(relative)
    if not REQUIRED.issubset({p.as_posix() for p in files}):
        raise ValueError("Missing plugin entry points")
    return files


def verify(archive, source):
    expected = {f"{PLUGIN}/{p.as_posix()}": (source / p).read_bytes()
                for p in release_files(source)}
    with zipfile.ZipFile(archive) as package:
        if package.testzip() is not None:
            raise ValueError("Corrupt ZIP")
        names = [entry.filename for entry in package.infolist()]
        if len(names) != len(set(names)):
            raise ValueError("Duplicate ZIP entries")
        for entry in package.infolist():
            parts = PurePosixPath(entry.filename).parts
            if (not parts or parts[0] != PLUGIN or ".." in parts
                    or "\\" in entry.filename
                    or any(p.startswith(".") or p == "spec" for p in parts)
                    or parts[-1] in PRIVATE
                    or stat.S_ISLNK(entry.external_attr >> 16)):
                raise ValueError(f"Unsafe ZIP entry: {entry.filename}")
        actual = {entry.filename: package.read(entry) for entry in package.infolist()
                  if not entry.is_dir()}
    if actual != expected:
        raise ValueError("ZIP does not match plugin source file for file")
    return len(actual)


def build(source, destination, tag=None):
    version_text = (source / "plugin_version.lua").read_text(encoding="utf-8")
    match = re.fullmatch(r'\s*return\s+["\']([0-9A-Za-z._+-]+)["\']\s*', version_text)
    if not match:
        raise ValueError("Invalid plugin version")
    version = match[1]
    if tag is not None and tag != f"v{version}":
        raise ValueError("Release tag must match plugin_version.lua")
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / "borges.koplugin.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as package:
        for relative in release_files(source):
            entry = zipfile.ZipInfo(f"{PLUGIN}/{relative.as_posix()}", (2000, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | 0o644) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            package.writestr(entry, (source / relative).read_bytes())
    count = verify(archive, source)
    # Keep versioned URLs used by existing integrations working.
    legacy = destination / f"{PLUGIN}-{version}.zip"
    legacy.write_bytes(archive.read_bytes())
    for path in (archive, legacy):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        path.with_name(path.name + ".sha256").write_text(f"{digest}  {path.name}\n", encoding="utf-8")
    print(f"Verified {count} plugin files; version {version}; {archive.name}")
    return archive


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag")
    parser.add_argument("--verify", type=Path)
    args = parser.parse_args()
    if args.verify:
        print(f"Verified {verify(args.verify, ROOT / PLUGIN)} plugin files")
    else:
        build(ROOT / PLUGIN, ROOT / "dist", args.tag)
