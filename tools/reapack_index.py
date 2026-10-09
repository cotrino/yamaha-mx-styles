#!/usr/bin/env python3
"""Generate this repository's ReaPack index without Ruby or native extensions."""

from __future__ import annotations

import argparse
import copy
import fnmatch
import os
import posixpath
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import PurePosixPath
from urllib.parse import quote


ROOT = PurePosixPath("yamaha_style_manager")
MAIN_SCRIPT = str(ROOT / "Yamaha_Style_Manager.lua")
INDEX_FILE = "index.xml"
CATEGORY = "Scripts/Yamaha_Style_Manager"


class IndexError(Exception):
    pass


def git(*args: str, text: bool = True) -> str | bytes:
    result = subprocess.run(
        ["git", *args],
        cwd=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=text,
    )
    if result.returncode:
        stderr = result.stderr.strip() if text else result.stderr.decode(errors="replace").strip()
        raise IndexError(f"git {' '.join(args)} failed: {stderr}")
    return result.stdout


def repo_root() -> str:
    return str(git("rev-parse", "--show-toplevel")).strip()


def read_blob(commit: str, path: str) -> str:
    data = git("show", f"{commit}:{path}", text=False)
    return data.decode("utf-8-sig")


def parse_manifest(text: str) -> dict:
    fields: dict[str, str] = {}
    provides: list[str] = []
    in_provides = False
    for line in text.splitlines():
        match = re.match(r"\s*--\s*@([\w-]+)\s*(.*)$", line)
        if match:
            key, value = match.groups()
            in_provides = key == "provides"
            if key != "provides":
                fields[key] = value.strip()
            elif value.strip():
                provides.append(value.strip())
            continue
        if in_provides:
            match = re.match(r"\s*--\s?(.*?)\s*$", line)
            if match and match.group(1):
                provides.append(match.group(1))
            else:
                in_provides = False
    if not fields.get("version"):
        raise IndexError("main script is missing @version metadata")
    if not fields.get("description"):
        raise IndexError("main script is missing @description metadata")
    return {**fields, "provides": provides}


def tracked_paths(commit: str) -> list[str]:
    data = git("ls-tree", "-r", "--name-only", "-z", commit, text=False)
    return [path.decode("utf-8") for path in data.split(b"\0") if path]


def expand_provides(manifest: dict, paths: list[str]) -> tuple[str, list[tuple[str, str]]]:
    main_path = MAIN_SCRIPT
    files: dict[str, str] = {}
    for rule in manifest["provides"]:
        main_match = re.match(r"^\[main\]\s+(.+)$", rule)
        if main_match:
            raw = (ROOT / main_match.group(1)).as_posix()
            if raw == ROOT.as_posix() or raw == f"{ROOT.as_posix()}/.":
                main_path = MAIN_SCRIPT
            else:
                candidates = [path for path in paths if path == raw]
                if len(candidates) != 1:
                    raise IndexError(f"@provides [main] path did not match one tracked file: {rule}")
                main_path = candidates[0]
            continue

        if rule.startswith("["):
            continue
        if ">" in rule:
            source_pattern, destination = (part.strip() for part in rule.split(">", 1))
        else:
            source_pattern, destination = rule.strip(), ""

        source_glob = posixpath.normpath((ROOT / source_pattern).as_posix())
        matches = [path for path in paths if fnmatch.fnmatchcase(path, source_glob)]
        for source in matches:
            if destination:
                dest = PurePosixPath(destination)
                package_path = (dest / PurePosixPath(source).name).as_posix()
            else:
                package_path = PurePosixPath(os.path.relpath(source, ROOT.as_posix()).replace("\\", "/")).as_posix()
            files[package_path] = source

    return main_path, sorted(files.items())


def raw_url(remote: str, commit: str, path: str) -> str:
    remote = remote.strip()
    if remote.startswith("git@github.com:"):
        remote = "https://github.com/" + remote.split(":", 1)[1]
    elif remote.startswith("ssh://git@github.com/"):
        remote = "https://github.com/" + remote.split("github.com/", 1)[1]
    remote = remote.removesuffix(".git").rstrip("/")
    if not remote.startswith("https://github.com/"):
        raise IndexError(f"origin must be a GitHub HTTPS or SSH URL, got: {remote}")
    return f"{remote}/raw/{commit}/{quote(path, safe='/@:+-._') }"


def version_commits() -> list[tuple[str, dict]]:
    commits = str(git("log", "--follow", "--reverse", "--format=%H", "--", MAIN_SCRIPT)).splitlines()
    versions: set[str] = set()
    result: list[tuple[str, dict]] = []
    for commit in commits:
        try:
            manifest = parse_manifest(read_blob(commit, MAIN_SCRIPT))
        except IndexError:
            continue
        if manifest["version"] not in versions:
            versions.add(manifest["version"])
            result.append((commit, manifest))
    if not result:
        raise IndexError(f"no versioned manifests found in history for {MAIN_SCRIPT}")
    return result


def commit_info(commit: str) -> tuple[str, str]:
    date = str(git("show", "-s", "--format=%aI", commit)).strip()
    parsed = datetime.fromisoformat(date.replace("Z", "+00:00")).astimezone(timezone.utc)
    return parsed.isoformat(timespec="seconds").replace("+00:00", "Z"), str(git("show", "-s", "--format=%an", commit)).strip()


def current_index() -> ET.Element:
    path = os.path.join(repo_root(), INDEX_FILE)
    try:
        return ET.parse(path).getroot()
    except (ET.ParseError, OSError) as exc:
        raise IndexError(f"cannot read existing {INDEX_FILE}: {exc}") from exc


def build_index() -> bytes:
    root = current_index()
    remote = str(git("remote", "get-url", "origin")).strip()
    old_package = root.find("./category/reapack")
    if old_package is None:
        raise IndexError("existing index has no package entry to preserve metadata")

    output = ET.Element("index", {"version": "1", "name": root.get("name", "ReaPack repository")})
    category = ET.SubElement(output, "category", {"name": CATEGORY})
    manifest_head = parse_manifest(read_blob(str(git("rev-parse", "HEAD")).strip(), MAIN_SCRIPT))
    package = ET.SubElement(
        category,
        "reapack",
        {"name": PurePosixPath(MAIN_SCRIPT).name, "type": "script", "desc": manifest_head["description"]},
    )
    old_metadata = old_package.find("metadata")
    if old_metadata is not None:
        package.append(copy.deepcopy(old_metadata))

    latest_commit = ""
    for commit, manifest in version_commits():
        paths = tracked_paths(commit)
        main_path, payload = expand_provides(manifest, paths)
        time, author = commit_info(commit)
        version = ET.SubElement(package, "version", {"name": manifest["version"], "author": manifest.get("author", author), "time": time})
        source = ET.SubElement(version, "source", {"main": "main"})
        source.text = raw_url(remote, commit, main_path)
        for package_path, source_path in payload:
            element = ET.SubElement(version, "source", {"file": package_path})
            element.text = raw_url(remote, commit, source_path)
        latest_commit = commit

    output.set("commit", latest_commit)
    ET.indent(output, space="  ")
    return b'<?xml version="1.0" encoding="utf-8"?>\n' + ET.tostring(output, encoding="utf-8") + b"\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="compare the committed index with generated output")
    mode.add_argument("--scan", action="store_true", help="write index.xml from versioned Git history (default)")
    parser.add_argument("--output", default=INDEX_FILE, help="index output path (default: index.xml)")
    args = parser.parse_args()

    try:
        generated = build_index()
        output_path = os.path.join(repo_root(), args.output)
        if args.check:
            with open(output_path, "rb") as handle:
                current = handle.read()
            if current != generated:
                print(f"{args.output} is out of date; run python tools/reapack_index.py --scan", file=sys.stderr)
                return 1
            print(f"{args.output} matches versioned Git history.")
            return 0
        with open(output_path, "wb") as handle:
            handle.write(generated)
        print(f"Wrote {args.output} from {len(version_commits())} version commits.")
        return 0
    except (IndexError, OSError) as exc:
        print(f"reapack_index: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())