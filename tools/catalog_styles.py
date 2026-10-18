"""Build a local, deduplicated Yamaha style catalog without redistributing sources.

Run with --apply to build Catalog, catalog.json/csv/html, and move original
inputs to _Sources. Originals are never deleted. Re-running verifies and
rebuilds the same catalog from those sources.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import html
import io
import json
import re
import shutil
import struct
import unicodedata
import zipfile
import zlib
from collections import Counter
from pathlib import Path, PurePosixPath
from urllib.parse import quote


STYLE_EXTENSIONS = {".sty", ".mid", ".midi", ".prs", ".sst", ".pcs", ".bcs", ".pst"}
MAX_ENTRY = 32 * 1024 * 1024
MAX_ARCHIVE = 512 * 1024 * 1024
SECTION = re.compile(r"^(?:Intro|Main|Ending)\s*[A-D]$|^Fill(?:\s*In)?\s*[A-D]{2}$|^Break$", re.I)
CATEGORIES = [
    ("01 Pop and Rock", "8 and 16 Beat", r"8b|8beat|16beat|12beat|8.?16"),
    ("02 Ballads and Easy Listening", "Ballads", r"ballad|bld|slow"),
    ("02 Ballads and Easy Listening", "Easy Listening", r"easy|easymedium|easYmedium"),
    ("03 Dance and Electronic", "Dance and Disco", r"dance|disco|techno|house|trance|eurobeat"),
    ("04 Jazz and Swing", "Big Band and Swing", r"big.?band|swing|shfl|shuffle"),
    ("04 Jazz and Swing", "Boogie and Ragtime", r"boogie|ragtime"),
    ("04 Jazz and Swing", "Jazz", r"jazz"),
    ("05 Soul Blues and Gospel", "Blues Soul and Gospel", r"blues|soul|gospel|rhythm.?and.?blues|r.?&.?b"),
    ("06 Country and Acoustic", "Country and Bluegrass", r"country|bluegrass|blue.?grass|hoedown|dixie"),
    ("06 Country and Acoustic", "Acoustic and Folk", r"unplugged|acoustic|accoustic|folk"),
    ("07 Latin", "Salsa Mambo and Samba", r"salsa|mambo|samba|conga"),
    ("07 Latin", "Bossa Rumba and Bolero", r"bossa|rumba|bolero"),
    ("07 Latin", "Brazilian and Caribbean", r"beguine|brazil|zouk|baiao|calypso|carib|danzon"),
    ("07 Latin", "Latin", r"latin|cumbia|ranchera|mexican|mexicano"),
    ("08 Ballroom", "Cha Cha and Tango", r"cha.?cha|tango|ballroom"),
    ("08 Ballroom", "Waltz", r"waltz|walzer|valse"),
    ("08 Ballroom", "Foxtrot and Quickstep", r"foxtrot|foxquick|qstep|quickstep|charleston"),
    ("08 Ballroom", "Paso Doble", r"paso"),
    ("09 World and Traditional", "March and Polka", r"march|polka"),
    ("09 World and Traditional", "European", r"europe|german|irish|scottish|armenia|greek"),
    ("09 World and Traditional", "Middle Eastern", r"oriental|turkey|turkish|iran|arab"),
    ("09 World and Traditional", "World", r"ethnic|world|e-other|e-americas"),
    ("10 Stage and Screen", "Stage and Classical", r"stage|ztage|screen|classi"),
    ("01 Pop and Rock", "Rock and Roll", r"rock|twist|jive"),
]


def safe_member(name: str) -> PurePosixPath:
    path = PurePosixPath(name.replace("\\", "/"))
    if path.is_absolute() or ".." in path.parts or any(":" in part for part in path.parts):
        raise ValueError(f"Unsafe archive entry: {name}")
    return path


def clean_name(name: str) -> str:
    name = unicodedata.normalize("NFKC", name)
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", name).strip(" .")
    name = re.sub(r"\s+", " ", name)
    if not name or name.split(".")[0].upper() in {"CON", "PRN", "AUX", "NUL", *(f"COM{i}" for i in range(10)), *(f"LPT{i}" for i in range(10))}:
        name = "_" + name
    return name[:100].rstrip(" .")


def display_name(name: str) -> str:
    # Older Mac ZIPs sometimes store UTF-8 names without setting the UTF-8 flag.
    try:
        name = name.encode("cp437").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        pass
    return unicodedata.normalize("NFC", name)


def classify(name: str, sources: list[str]) -> tuple[str, str]:
    context = " ".join(sources)
    if re.search(r"christmas|xmas", name + " " + context, re.I):
        return "11 Song Collections", "Christmas"
    if re.search(r"elvis", context, re.I):
        return "11 Song Collections", "Elvis"
    # Filename and deepest source folders are more specific than a mixed archive title.
    for text in [name, *reversed(re.split(r"[/\\!]", context))]:
        for category, subcategory, pattern in CATEGORIES:
            if re.search(pattern, text, re.I):
                return category, subcategory
    return "12 Uncategorized", "Review"


def midi_metadata(data: bytes) -> dict:
    header = data.find(b"MThd", 0, 1024)
    if header < 0 or len(data) < header + 14:
        raise ValueError("No complete Standard MIDI header")
    length, fmt, tracks, ppq = struct.unpack_from(">IHHH", data, header + 4)
    if length < 6 or fmt > 1 or not tracks or not ppq or ppq & 0x8000:
        raise ValueError("Unsupported MIDI header/timing")
    pos, end_tick, sections, tempos, meters, channels = header + 8 + length, 0, [], [], [], set()
    warnings = []

    def vlq(buf, offset):
        value = 0
        for _ in range(4):
            byte = buf[offset]
            offset += 1
            value = (value << 7) | (byte & 127)
            if not byte & 128:
                return value, offset
        raise ValueError("Invalid MIDI variable-length quantity")

    for _ in range(tracks):
        if data[pos:pos + 4] != b"MTrk" or pos + 8 > len(data):
            raise ValueError("Missing MIDI track")
        size = struct.unpack_from(">I", data, pos + 4)[0]
        if data[pos + 8 + size - 2:pos + 8 + size + 1] == b"\xff\x2f\x00":
            size += 1
            warnings.append("Track length omits the final end-of-track zero byte")
        buf = data[pos + 8:pos + 8 + size]
        if len(buf) != size:
            raise ValueError("Truncated MIDI track")
        pos += 8 + size
        offset, tick, running = 0, 0, None
        while offset < len(buf):
            delta, offset = vlq(buf, offset)
            tick += delta
            status = buf[offset]
            if status >= 128:
                offset += 1
            elif running is not None:
                status = running
            else:
                raise ValueError("Missing MIDI running status")
            if status == 255:
                kind = buf[offset]
                size, offset = vlq(buf, offset + 1)
                payload = buf[offset:offset + size]
                if len(payload) != size:
                    raise ValueError("Truncated meta event")
                offset += size
                if kind in (1, 6):
                    label = payload.decode("latin1").strip("\x00 \r\n")
                    if SECTION.fullmatch(label):
                        sections.append({"name": label, "tick": tick})
                elif kind == 81 and size == 3 and int.from_bytes(payload, "big"):
                    tempos.append((tick, round(60000000 / int.from_bytes(payload, "big"), 2)))
                elif kind == 88 and size >= 2:
                    meters.append((tick, f"{payload[0]}/{2 ** payload[1]}"))
                if kind == 47:
                    break
            elif status in (240, 247):
                running = None
                size, offset = vlq(buf, offset)
                offset += size
            elif 128 <= status <= 239:
                running = status
                size = 1 if status & 240 in (192, 208) else 2
                if offset + size > len(buf) or any(b >= 128 for b in buf[offset:offset + size]):
                    raise ValueError("Invalid MIDI event data")
                channels.add((status & 15) + 1)
                offset += size
            else:
                raise ValueError(f"Unsupported MIDI status {status:02x}")
            if offset > len(buf):
                raise ValueError("Truncated MIDI event")
        end_tick = max(end_tick, tick)
    sections = [dict(name=name, tick=tick) for tick, name in sorted({(s["tick"], s["name"]) for s in sections})]
    return {"ppq": ppq, "quarter_notes": round(end_tick / ppq, 3), "sections": sections,
            "tempo": min(tempos)[1] if tempos else None, "meter": min(meters)[1] if meters else None,
            "channels": sorted(channels), "warnings": warnings}


def archive_entries(data: bytes, source: str, issues: list[dict]):
    """Read ordinary ZIPs or CRC-verified local records of a truncated ZIP."""
    if len(data) > MAX_ARCHIVE:
        raise ValueError(f"Archive exceeds size limit: {source}")
    if zipfile.is_zipfile(io.BytesIO(data)):
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            total = 0
            for entry in archive.infolist():
                path = safe_member(entry.filename)
                if entry.is_dir() or "__MACOSX" in path.parts or path.name.startswith("._") or path.name == ".DS_Store":
                    continue
                total += entry.file_size
                if entry.file_size > MAX_ENTRY or total > MAX_ARCHIVE:
                    raise ValueError(f"Archive expansion exceeds limit: {source}")
                yield str(path), archive.read(entry)
        return
    issues.append({"source": source, "status": "recovered-partial-archive", "detail": "Central directory missing; recovering only complete CRC-verified local entries. Original retained."})
    pos, recovered = 0, 0
    while data[pos:pos + 4] == b"PK\x03\x04":
        if len(data) < pos + 30:
            break
        _, flags, method, _, _, crc, packed, size, namesize, extrasize = struct.unpack_from("<HHHHHIIIHH", data, pos + 4)
        if flags & 9 or size > MAX_ENTRY or packed > MAX_ENTRY:
            break
        name_start, start = pos + 30, pos + 30 + namesize + extrasize
        if start + packed > len(data):
            break
        name = data[name_start:name_start + namesize].decode("utf-8" if flags & 2048 else "cp437")
        path = safe_member(name)
        packed_data = data[start:start + packed]
        if method == 0:
            payload = packed_data
        elif method == 8:
            inflater = zlib.decompressobj(-15)
            payload = inflater.decompress(packed_data, MAX_ENTRY + 1)
            if not inflater.eof:
                break
        else:
            break
        if len(payload) != size or zlib.crc32(payload) != crc:
            break
        pos, recovered = start + packed, recovered + 1
        if not name.endswith("/") and "__MACOSX" not in path.parts and not path.name.startswith("._") and path.name != ".DS_Store":
            yield str(path), payload
    if not recovered:
        raise ValueError(f"No recoverable ZIP entries: {source}")
    issues.append({"source": source, "status": "archive-recovery-boundary", "detail": f"Verified {recovered} local records; stopped at byte {pos} of {len(data)}."})


def build(root: Path, apply: bool = False) -> dict:
    root = root.resolve()
    previous = json.loads((root / "catalog.json").read_text(encoding="utf-8")) if (root / "catalog.json").exists() else {}
    originals = root / "_Sources" / "Originals"
    inputs = sorted([p for p in root.iterdir() if p.name not in {"Catalog", "_Sources", "catalog.json", "catalog.csv", "catalog.html"}], key=lambda p: p.name.lower())
    files = sorted([p for top in inputs for p in ([top] if top.is_file() else top.rglob("*")) if p.is_file()] +
                   ([p for p in originals.rglob("*") if p.is_file()] if originals.exists() else []), key=lambda p: str(p).lower())
    styles, assets, issues = {}, {}, []
    source_files = []

    def ingest(name, data, source, depth=0):
        if depth > 4:
            raise ValueError(f"Nested archive depth exceeded: {source}")
        if Path(name).suffix.lower() == ".zip":
            for member, payload in archive_entries(data, source, issues):
                ingest(member, payload, source + "!" + member, depth + 1)
            return
        digest = hashlib.sha256(data).hexdigest()
        if Path(name).suffix.lower() not in STYLE_EXTENSIONS:
            assets.setdefault(digest, {"name": name, "data": data, "sources": []})["sources"].append(source)
            return
        try:
            metadata = midi_metadata(data)
        except (ValueError, IndexError, struct.error) as exc:
            issues.append({"source": source, "status": "invalid-style", "detail": str(exc)})
            assets.setdefault(digest, {"name": name, "data": data, "sources": []})["sources"].append(source)
            return
        row = styles.setdefault(digest, {"sha256": digest, "bytes": len(data), "name": display_name(Path(name).stem),
                                         "sources": [], "data": data, **metadata})
        row["sources"].append(source)

    for path in files:
        source = path.relative_to(originals if path.is_relative_to(originals) else root).as_posix()
        data = path.read_bytes()
        source_files.append({"path": source, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        ingest(path.name, data, source)

    rows, destinations = [], set()
    for digest, row in sorted(styles.items()):
        category, subcategory = classify(row["name"], row["sources"])
        name = clean_name(row["name"])
        relative = Path("Catalog") / category / subcategory / f"{name} [{digest[:12]}].sty"
        if str(relative).lower() in destinations:
            raise ValueError(f"Catalog destination collision: {relative}")
        destinations.add(str(relative).lower())
        payload = row.pop("data")
        row.update(category=category, subcategory=subcategory, path=relative.as_posix())
        if apply:
            target = root / relative
            if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() != digest:
                raise FileExistsError(f"Catalog file modified; refusing overwrite: {target}")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(payload)
        rows.append(row)
    rows.sort(key=lambda r: (r["category"], r["subcategory"], r["name"].lower(), r["sha256"]))
    for digest, asset in assets.items():
        if apply:
            target = root / "_Sources" / "Supporting Files" / f"{digest[:12]}_{clean_name(Path(asset['name']).name)}"
            if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() != digest:
                raise FileExistsError(f"Supporting file modified: {target}")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(asset["data"])
        asset.pop("data")
        asset["sha256"] = digest
    inventory = {"schema": 1, "style_count": len(rows), "source_style_count": sum(len(r["sources"]) for r in rows),
                 "duplicates": sum(len(r["sources"]) - 1 for r in rows), "source_files": source_files,
                 "categories": dict(sorted(Counter(r["category"] for r in rows).items())),
                 "issues": issues, "supporting_files": list(assets.values()), "styles": rows}
    if apply:
        (root / "catalog.json").write_text(json.dumps(inventory, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
        with (root / "catalog.csv").open("w", newline="", encoding="utf-8-sig") as handle:
            fields = ["name", "category", "subcategory", "tempo", "meter", "quarter_notes", "path", "sha256", "sources"]
            writer = csv.DictWriter(handle, fields, extrasaction="ignore")
            writer.writeheader()
            for row in rows:
                writer.writerow({**row, "sources": " | ".join(row["sources"])})
        body = "\n".join("<tr>" + "".join(f"<td>{html.escape(str(row.get(k) or ''))}</td>" for k in ("name", "category", "subcategory", "tempo", "meter")) +
                         f'<td><a href="{html.escape(quote(row["path"]), quote=True)}">Style</a></td></tr>' for row in rows)
        page = """<!doctype html><html lang="en"><meta charset="utf-8"><title>Yamaha Style Catalog</title>
<style>body{font:16px system-ui;margin:2em;background:#16212a;color:#eee}input{padding:.6em;width:40em}
table{border-collapse:collapse;width:100%}td,th{text-align:left;padding:.5em;border-bottom:1px solid #465}
a{color:#8cf}th{position:sticky;top:0;background:#16212a}</style><h1>Yamaha Style Catalog</h1>
<p>Local library. Original sources and provenance are retained in catalog.json and _Sources.</p>
<input id="search" type="search" placeholder="Search name, genre, tempo or meter" aria-label="Search catalog">
<table><thead><tr><th>Name</th><th>Genre</th><th>Subgenre</th><th>BPM</th><th>Meter</th><th>File</th></tr></thead><tbody>""" + body + """</tbody></table>
<script>document.querySelector('#search').addEventListener('input', e => {
const q=e.target.value.toLowerCase();document.querySelectorAll('tbody tr').forEach(r=>r.hidden=!r.textContent.toLowerCase().includes(q));});</script></html>"""
        (root / "catalog.html").write_text(page, encoding="utf-8")
        # Verify the persistent catalog before relocating the originals.
        for row in rows:
            if hashlib.sha256((root / row["path"]).read_bytes()).hexdigest() != row["sha256"]:
                raise ValueError(f"Catalog verification failed: {row['path']}")
        for row in previous.get("styles", []):
            old = (root / row["path"]).resolve()
            if str(Path(row["path"])).lower() not in destinations and old.exists():
                if not old.is_relative_to(root / "Catalog") or hashlib.sha256(old.read_bytes()).hexdigest() != row["sha256"]:
                    raise ValueError(f"Refusing to remove a modified or unexpected old catalog file: {old}")
                old.unlink()
        for source in inputs:
            target = originals / source.name
            if target.exists():
                raise FileExistsError(f"Original source destination already exists: {target}")
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(source), str(target))
    return inventory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1] / "styles")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    result = build(args.root, args.apply)
    print(json.dumps({k: v for k, v in result.items() if k not in {"styles", "supporting_files", "source_files", "issues"}}, indent=2))
    print("Issues:", dict(Counter(row["status"] for row in result["issues"])))
    for row in result["issues"][:10]:
        print(json.dumps(row))


if __name__ == "__main__":
    main()
