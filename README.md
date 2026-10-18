# Yamaha MX Styles

ReaPack repository for the **Yamaha STY Style Manager & Live Rig Builder**.

The package is in [`yamaha_style_manager`](./yamaha_style_manager). Yamaha style files are not redistributed by this repository. Configure your own local style-library folder in the ReaScript.

## Professional local catalog

Run the organizer against your local `styles` folder:

```powershell
python tools\catalog_styles.py
python tools\catalog_styles.py --apply
```

The first command previews the inventory; `--apply` builds and verifies it:

- `styles/Catalog/<genre>/<subgenre>/`: usable styles, deduplicated by SHA-256. Distinct versions of the same title keep separate hash-suffixed names.
- `styles/catalog.html`: searchable offline browser with links to the styles.
- `styles/catalog.csv` and `styles/catalog.json`: metadata, BPM, meter, sections, file hashes, source aliases, and explicit warnings.
- `styles/_Sources/Originals/`: all original archives and loose collections, retained unchanged.
- `styles/_Sources/Supporting Files/`: unpacked non-style files and malformed style candidates. Their original paths and rejection reasons are in the JSON inventory.

The organizer also recognizes MIDI-based Yamaha `.prs`, `.sst`, `.pcs`, `.bcs`, and `.pst` variants and catalogs them as `.sty` without changing their contents. It recovers only complete CRC-verified records from truncated ZIPs and reports the recovery boundary. It does not invent missing data. OS metadata stays in the original archives instead of cluttering the catalog.

Classification uses the title and source collection/folder names. Ambiguous material remains under **Uncategorized / Review**, not an invented genre. Re-running is safe: originals are retained, modified catalog files are not overwritten, and every canonical file is hash-verified. The ReaScript skips `_Sources` and searches matching styles across all folders.

MIDI files without recognized Yamaha section markers remain in the catalog with an empty `sections` list; they are not silently presented as fully sectioned styles. The importer reports that they need section markers rather than creating a nonfunctional arranger rig.

## MX88 voices and per-section arpeggios

Install the companion [Yamaha MX Genos Suite](https://github.com/cotrino/yamaha-mx-genos-suite) **1.1.0 or newer**. Import a style, open **MX88 voices / Genos Inspector**, and open the Inspector. Select a **Style section** and **Style channel** there, then choose a native MX voice and arpeggio. Selections are stored in the existing MIDI item, independently for each section/channel, without adding preview notes. The MX supports two simultaneous arpeggio parts; the editor prevents enabling a third in the same section.

Imported GM/XG selections are translated to real MX preset bank/program addresses, not sent as unrelated MX programs or left as generic GM voices. The soloist selector also lists native MX presets. See the [manager documentation](./yamaha_style_manager/README.md) for details.

## ReaPack

Import `https://raw.githubusercontent.com/cotrino/yamaha-mx-styles/master/index.xml` into ReaPack, then install the script from `Scripts/Yamaha_Style_Manager`. Add the companion suite's `https://raw.githubusercontent.com/cotrino/yamaha-mx-genos-suite/master/index.xml` as well. Style-library files and local verification projects are deliberately excluded from both packages.

## Verification

```powershell
python -m unittest discover -s tools -p "test_catalog_styles.py" -v
python -m unittest discover -s tools -p "test_style_modules.py" -v
python tools\reapack_index.py --check
```

Lua module tests require the optional Python `lupa` package (Lua 5.4). Both repositories should be sibling checkouts for those integration tests. Run `tools/verify_reaper.lua` in REAPER for real import, native voice, section-edit, arpeggio, note-preservation, reimport and ReaImGui checks. It opens a separate project tab, disables that test rig's hardware MIDI outputs, and writes a report and project under local `build/`. It does not edit the previously active project.
