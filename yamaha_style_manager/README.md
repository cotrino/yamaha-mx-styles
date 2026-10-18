# Yamaha STY Style Manager & Live Rig Builder

ReaImGui ReaScript for importing Yamaha `.sty` Standard MIDI files into a Yamaha MX88-oriented REAPER live rig.
The style manager uses the Yamaha MX Genos Suite's voice catalog and MIDI driver for MX88 voice selection and
section-specific arpeggio settings.

## Install

Add this repository's raw `index.xml` URL to ReaPack, install **Yamaha STY Style Manager & Live Rig Builder**, and run it from **Actions**. ReaImGui is required; SWS is recommended. Install Yamaha MX Genos Suite **1.1.0+** separately, then select its script folder in **MX88 voices / Genos Inspector** if it is not found automatically. A valid MX voice catalog, arpeggio data and section-editing module are required before importing.

The default library location is `C:\Users\josem\workarea\yamaha-mx-styles\styles`; change it from **Config Directory**. The script stores the selected path in REAPER's `YamahaStyleManager/RootFolder` ExtState.

## Behavior

- Recursively searches `.sty` and `.mid` files.
- Parses Standard MIDI tracks, style section text/marker events, and MIDI channels 9-16.
- Maps imported part voices to names from the Yamaha MX catalog and preserves supported voice changes at section boundaries.
- Creates an MX88 folder rig, a Channel 1 chord-input track routed through per-part transposers, section regions, and a Launchpad control track.
- Opens the Genos Inspector against imported style tracks so voice and arpeggio choices can be written into the selected section's MIDI.
- Saves native MX bank/program selections, arpeggio number/on-off state, reverb, chorus, cutoff and resonance per section/channel while preserving the original notes and all other sections.
- Restores the destination section's saved voice, effects and arpeggio when changing sections or resending voices.
- Starts arpeggiators OFF and enforces the MX limit of two simultaneous arpeggio parts per section.
- Imports the source's initial tempo and meter at project start. Import replaces earlier style rigs and their owned regions; unrelated tracks, markers and regions are kept. Use a separate project for a live rig if other material must retain its tempo map.
- Supports offline section editing without an attached Yamaha output. In style projects the Inspector leaves Launchpad/nanoKEY control to the style manager instead of running a second hardware controller.
- Targets detected `Yamaha MX88` and `Launchpad` device names; it never guesses a hardware output when a device is absent.

Style files are deliberately not packaged: configure their local folder in the UI.

## Soloist voices and level

The Active Chord window and Launchpad middle row select native MX presets:
CncrtGrand, Vintage'74, Jz2Perc+C3, Classical, Vln Solo 1, Trumpet 1,
AltoVibLeg and Sweet Flt. The window shows the actual preset names and also
offers all native normal-voice presets for immediate selection.
The selected-voices list reads each part's bank/program at the current
play/cursor position, including edits made in the Genos Inspector.

**Solo volume (CC7)** defaults to 120/127 and is saved across runs. Selecting
or resending a solo voice restores this level and full expression (CC11=127),
neutral cutoff/resonance and arpeggiator-off, so a previously attenuated part
does not stay quiet. Subsequent expression-pedal input still works normally.
This controls MIDI part level, not the keyboard's master/audio-output level.

Run the ReaPack action installed under `Yamaha MX Styles/Scripts/Yamaha_Style_Manager`.
An older manual installation under `Yamaha STY Style Manager` is a different
action and does not receive ReaPack updates. Close any running old manager
before launching the updated action.

## Editing a section

1. Import a style, expand **MX88 voices / Genos Inspector**, and click **Open Genos Inspector**.
2. Select an imported channel track. The Inspector shows **Style section** and **Style channel** selectors.
3. Select a section and channel, then pick the desired MX voice. The voice list excludes GM banks in style mode.
4. Pick an arpeggio and enable **Arpeggiator** if needed. More than two enabled parts in one section produces an explicit error.
5. Use **Apply Voice / Arpeggio to Style Section** to save controller-slider edits. Voice/arpeggio picks are applied immediately.
6. Save the REAPER project. Changes live in the project MIDI, not in the source style file; no overlapping preview notes or extra items are created.

Older imported rigs without region-ownership tags must be reimported to use the section editor. The importer cannot safely identify their old regions, so it leaves those unowned regions for manual cleanup.
