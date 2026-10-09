# Specification Prompt: REAPER Yamaha STY Style Manager & Rig Builder for Yamaha MX88 & Novation Launchpad

## 1. Project Overview & Goal
Build a **ReaPack-compatible ReaScript** in Lua using **ReaImGui** titled `Yamaha STY Style Manager & Live Rig Builder`. 

The plugin must:
1. Scan a user-configured root directory containing Yamaha `.sty` files (including subdirectories).
2. Display a searchable file browser tree.
3. Import a selected `.sty` file into the current REAPER project.
4. Automatically generate a complete multitrack live performance rig for the **Yamaha MX88** synthesizer and **Novation Launchpad Mini**.
5. Create region-based section structures (`Main A-D`, `Fill In AA-DD`, `Intro A-D`, `Ending A-D`) with measure-quantized smooth seeking (`Smooth Seek`).
6. Set up MIDI routing and LED feedback for the Launchpad.

---

## 2. Technical Stack & Dependencies (Token-Minimization Strategy)
To minimize code generation and avoid reinventing existing functionality, **REUSE** the following native REAPER, SWS, and JSFX components:

- **GUI Framework:** `ReaImGui` (v0.8+ via ReaPack).
- **SWS Extension Actions:** 
  - Smooth seeking region navigation (`SWS/S&M: Go to region 01..16 (smooth seek)`).
  - Region creation and marker utilities.
- **Native JSFX Plugins:**
  - `JS: MIDI Pitch Transpose` (inserted on input track for chord transposition).
  - `JS: IX/MIDI_Router` or `JS: MIDI Channel Router` for channel splitting.
- **Hardware Integration Target:**
  - **Yamaha MX88:** Multitimbral performance mode (16 channels).
  - **Novation Launchpad:** MIDI Note/CC triggering + SysEx/Note velocity LED feedback.

---

## 3. Core Architecture & File Structure

Generate the following file structure for the ReaPack repository:


```

yamaha_style_manager/
├── index.xml                         # ReaPack package index file
├── Yamaha_Style_Manager.lua          # Main ReaImGui application & logic
├── modules/
│   ├── sty_parser.lua                # MIDI binary parser for .sty markers & events
│   ├── mx88_mapper.lua               # MSB/LSB bank & program change generator for MX88
│   ├── region_builder.lua            # REAPER Region & Smooth Seek manager
│   └── launchpad_controller.lua      # Launchpad MIDI routing & LED feedback setup
└── jsfx/
└── sty_chord_transposer.jsfx     # Lightweight JSFX for live chord transposition

```

---

## 4. Detailed Component Specifications

### 4.1. File Scanner & ReaImGui Browser (`Yamaha_Style_Manager.lua`)
- **Config Storage:** Save/Load root folder path in REAPER ExtState (`reaper.SetExtState("YamahaStyleManager", "RootFolder", path, true)`).
- **Tree View:** Render subdirectories recursively using `imgui.TreeNode`.
- **Search Filter:** Text input box filtering `.sty` and `.mid` files in real time.
- **Action Buttons:** `[ Import Style to Rig ]`, `[ Refresh Library ]`, `[ Config Directory ]`.

### 4.2. STY Binary Parser (`modules/sty_parser.lua`)
Yamaha `.sty` files are Standard MIDI Format (SMF Type 0 or 1) with custom headers.
- **Parser Logic:**
  - Parse track meta-events (Meta Type `0x01` Text and `0x06` Marker).
  - Extract section labels: `Intro A-D`, `Main A-D`, `Fill In AA-DD`, `Ending A-D`, `Break`.
  - Calculate tick-to-time position (PPQ to Project Time) for each marker.
  - Extract 16-channel MIDI events (Channels 9 & 10 = Drums/Percussion, Channel 11 = Bass, Channels 12-16 = Chords/Phrases).

### 4.3. Yamaha MX88 Rig Generator (`modules/mx88_mapper.lua`)
Create a **Folder Track** named `[YAMAHA STY RIG] - <StyleName>` containing 8 child tracks:
1. `Ch 9: Rhythm 2 (Percussion)`
2. `Ch 10: Rhythm 1 (Drums)`
3. `Ch 11: Bass`
4. `Ch 12: Chord 1`
5. `Ch 13: Chord 2`
6. `Ch 14: Pad / Strings`
7. `Ch 15: Phrase 1`
8. `Ch 16: Phrase 2`

**MX88 Bank Select Injection:**
- For **Tracks 1-8** (Normal Voices): Inject `CC 0 (MSB) = 63`, `CC 32 (LSB) = 0` at PPQ 0.
- For **Drums/Percussion (Ch 9 & 10)**: Inject `CC 0 (MSB) = 63`, `CC 32 (LSB) = 32` at PPQ 0.
- Set track hardware MIDI outputs to `Yamaha MX88` on channels 9 through 16 respectively.

### 4.4. Region & Smooth Seek Manager (`modules/region_builder.lua`)
1. Clear existing style regions (or append after project end).
2. For each parsed marker (`Main A`, `Fill AA`, etc.):
   - Call `reaper.AddProjectMarker2(0, true, start_time, end_time, section_name, -1, color)`.
3. Set REAPER Project Preferences via API:
   - `seekplay = 1` (Seek on play item click / marker change).
   - `smoothseek = 1` (Smooth seek enabled).
   - `smoothseek_mode = 2` (Quantize seek to end of current measure).

### 4.5. Launchpad Integration & Feedback (`modules/launchpad_controller.lua`)
1. Create a dedicated MIDI Control Track named `[MIDI] Launchpad Controller`.
2. Map Launchpad Grid Pads (8x8) to Regions:
   - **Row 1 (Top):** Intros (`Intro A` - `Intro D`) $\rightarrow$ Color: **Amber/Yellow**
   - **Row 2:** Mains (`Main A` - `Main D`) $\rightarrow$ Color: **Green**
   - **Row 3:** Fills (`Fill AA` - `Fill DD`) $\rightarrow$ Color: **Orange**
   - **Row 4:** Endings (`Ending A` - `Ending D`) $\rightarrow$ Color: **Red**
3. **Action Bindings:** Use `reaper.SetBindingByActionID` or map custom ReaScript action shortcuts to SWS Smooth Seek region actions (`_SWS_SM_GOTO_REG1` through `_SWS_SM_GOTO_REG16`).
4. **LED Feedback:** Send MIDI Note On messages back to Launchpad MIDI Output port with specific velocity bytes for colors.

### 4.6. Live Chord Transposer JSFX (`jsfx/sty_chord_transposer.jsfx`)
Write a minimal JSFX plugin inserted on the MIDI Input track:
- Listens to incoming chords on **MIDI Channel 1** (Left Hand on Yamaha MX88).
- Detects the root note of the pressed chord.
- Dynamically transposes outgoing MIDI events on Channels 9-16 relative to the style's base key (C Major).

---

## 5. Coding Principles & Guidelines for Copilot
- **Language:** Pure Lua 5.3+ (REAPER API compliant) and EEL2/JSFX.
- **Error Handling:** Wrap file I/O and MIDI parsing in `pcall()` blocks to prevent GUI crashes on corrupted `.sty` files.
- **Clean Architecture:** Keep UI rendering separate from MIDI/file parsing logic.
- **ReaPack Formatting:** Include standard ReaPack header metadata comments in `Yamaha_Style_Manager.lua` (`@description`, `@version`, `@author`, `@provides`).

---

## 6. Verification Steps
Upon code generation, ensure:
1. Running `Yamaha_Style_Manager.lua` opens a ReaImGui window showing subfolders and `.sty` files.
2. Clicking **Import** imports the file, splits it into 8 tracks, sets MX88 MSB/LSB CCs, and creates project regions.
3. Pressing Launchpad pads smoothly switches playback regions at the end of the measure.
