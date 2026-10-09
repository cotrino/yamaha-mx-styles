#!/usr/bin/env python3
"""Generate the ReaPack index from versioned package manifests."""

from __future__ import annotations

import argparse
import fnmatch
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import PurePosixPath
from urllib.parse import quote

ROOT = PurePosixPath("yamaha_style_manager")
MAIN = ROOT / "Yamaha_Style_Manager.lua"


class IndexError(Exception):
    pass


def git(*args: str, binary: bool = False) -> str | bytes:
    result = subprocess.run(["git", *args], cwd=ROOT_DIR, capture_output=True, text=not binary)
    if result.returncode:
        raise IndexError(result.stderr.decode(errors="replace") if binary else result.stderr.strip())
    return result.stdout


def manifest(text: str) -> tuple[dict[str, str], list[str]]:
    fields, provides, in_provides = {}, [], False
    for line in text.splitlines():
        match = re.match(r"\s*--\s*@([\w-]+)\s*(.*)$", line)
        if match:
            key, value = match.groups()
            in_provides = key == "provides"
            if key == "provides":
                if value.strip():
                    provides.append(value.strip())
            else:
                fields[key] = value.strip()
        elif in_provides:
            match = re.match(r"\s*--\s?(.*?)\s*$", line)
            if match and match.group(1):
                provides.append(match.group(1))
            else:
                in_provides = False
    if not fields.get("version") or not fields.get("description"):
        raise IndexError("main script is missing @version or @description")
    return fields, provides


def blob(commit: str, path: PurePosixPath) -> str:
    return bytes(git("show", f"{commit}:{path.as_posix()}", binary=True)).decode("utf-8-sig")


def sources(commit: str, rules: list[str]) -> list[tuple[str, str]]:
    paths = bytes(git("ls-tree", "-rz", "--name-only", commit, binary=True)).split(b"\0")
    paths = [path.decode() for path in paths if path]
    result = []
    for rule in rules:
        if rule.startswith("["):
            continue
        source, _, destination = rule.partition(">")
        pattern = (ROOT / source.strip()).as_posix()
        for path in paths:
            if fnmatch.fnmatchcase(path, pattern):
                target = (PurePosixPath(destination.strip()) / PurePosixPath(path).name).as_posix() if destination else str(PurePosixPath(path).relative_to(ROOT))
                result.append((target, path))
    return sorted(set(result))


def raw_url(remote: str, commit: str, path: str) -> str:
    remote = remote.removesuffix(".git").rstrip("/")
    if remote.startswith("git@github.com:"):
        remote = "https://github.com/" + remote.split(":", 1)[1]
    if not remote.startswith("https://github.com/"):
        raise IndexError("origin must be a GitHub URL")
    return f"{remote}/raw/{commit}/{quote(path, safe='/@:+-._')}"


def build() -> bytes:
    remote = str(git("remote", "get-url", "origin")).strip()
    commits = str(git("log", "--follow", "--reverse", "--format=%H", "--", MAIN.as_posix())).splitlines()
    root = ET.Element("index", {"version": "1", "name": "Yamaha MX Styles"})
    category = ET.SubElement(root, "category", {"name": "Scripts/Yamaha_Style_Manager"})
    package = ET.SubElement(category, "reapack", {
        "name": MAIN.name, "type": "script", "desc": "Yamaha STY Style Manager & Live Rig Builder",
    })
    metadata = ET.SubElement(package, "metadata")
    ET.SubElement(metadata, "description").text = "Browse Yamaha STY files and create an MX88/Launchpad live rig."
    seen, last_commit = set(), ""
    for commit in commits:
        fields, rules = manifest(blob(commit, MAIN))
        if fields["version"] in seen:
            continue
        seen.add(fields["version"])
        date = str(git("show", "-s", "--format=%aI", commit)).strip()
        timestamp = datetime.fromisoformat(date.replace("Z", "+00:00")).astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
        version = ET.SubElement(package, "version", {"name": fields["version"], "author": fields.get("author", ""), "time": timestamp})
        ET.SubElement(version, "source", {"main": "main"}).text = raw_url(remote, commit, MAIN.as_posix())
        for target, source in sources(commit, rules):
            ET.SubElement(version, "source", {"file": target}).text = raw_url(remote, commit, source)
        last_commit = commit
    if not last_commit:
        raise IndexError("no versioned script commits found")
    root.set("commit", last_commit)
    ET.indent(root, space="  ")
    return b'<?xml version="1.0" encoding="utf-8"?>\n' + ET.tostring(root, encoding="utf-8") + b"\n"


ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        output = build()
        path = os.path.join(ROOT_DIR, "index.xml")
        if args.check:
            return 0 if open(path, "rb").read() == output else 1
        open(path, "wb").write(output)
        return 0
    except (OSError, IndexError) as error:
        print(f"reapack_index: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
