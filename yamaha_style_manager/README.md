# Yamaha STY Style Manager & Live Rig Builder

ReaImGui ReaScript for importing Yamaha `.sty` Standard MIDI files into a Yamaha MX88-oriented REAPER live rig.

## Install

Add this repository's raw `index.xml` URL to ReaPack, install **Yamaha STY Style Manager & Live Rig Builder**, and run it from **Actions**. ReaImGui and SWS are recommended dependencies.

The default library location is `C:\Users\josem\workarea\yamaha-mx-styles\styles`; change it from **Config Directory**. The script stores the selected path in REAPER's `YamahaStyleManager/RootFolder` ExtState.

## Behavior

- Recursively searches `.sty` and `.mid` files.
- Parses Standard MIDI tracks, style section text/marker events, and MIDI channels 9-16.
- Creates an MX88 folder rig, an input transposer track, section regions, and a Launchpad control track.
- Targets detected `Yamaha MX88` and `Launchpad` device names; it never guesses a hardware output when a device is absent.

Style files are deliberately not packaged: configure their local folder in the UI.
