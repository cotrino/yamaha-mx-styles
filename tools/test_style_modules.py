"""Regression tests using the Lua 5.4 runtime supplied by the optional lupa package."""

import struct
import tempfile
import unittest
from pathlib import Path

from lupa.lua54 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
SUITE = ROOT.parent / "yamaha-mx-genos-suite" / "Scripts" / "Yamaha_MX_Genos_Suite"


class StyleModuleTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().reaper = self.lua.table()

    def module(self, path):
        return self.lua.execute("return dofile(...)", str(path))

    def mapper(self):
        self.lua.globals().module_dir = str(ROOT / "yamaha_style_manager" / "modules")
        self.lua.execute("package.path = module_dir .. '\\\\?.lua;' .. package.path")
        driver = self.module(SUITE / "lib" / "midi_yamaha_driver.lua")
        driver.init(str(SUITE / "data" / "Yamaha_MX49.reabank"),
                    str(SUITE / "data" / "Yamaha_MX88_Arpeggios.csv"))
        mapper = self.lua.eval("require('mx88_mapper')")[0]
        mapper.configure(driver)
        return mapper, driver

    def test_solo_shortcuts_use_named_native_presets(self):
        self.mapper()
        mapping = self.lua.eval("package.loaded.voice_map")
        expected = {
            0: (0, 0, "CncrtGrand"), 4: (0, 21, "Vintage'74"),
            19: (0, 82, "Jz2Perc+C3"), 24: (1, 49, "Classical"),
            40: (2, 126, "Vln Solo 1"), 56: (3, 68, "Trumpet 1"),
            65: (4, 2, "AltoVibLeg"), 73: (4, 15, "Sweet Flt"),
        }
        for program, (lsb, prg, name) in expected.items():
            voice = mapping.solo(program)
            self.assertEqual((voice.msb, voice.lsb, voice.prg), (63, lsb, prg))
            self.assertTrue(voice.name.endswith(name), voice.name)

    def test_solo_resend_restores_level_expression_and_native_voice(self):
        self.lua.execute("""
          messages, settings = {}, {}
          reaper.GetExtState = function(_, key) return settings[key] or "" end
          reaper.GetPlayState = function() return 0 end
          reaper.GetCursorPosition = function() return 0 end
          reaper.StuffMIDIMessage = function(port, status, d1, d2)
            messages[#messages + 1] = {port, status, d1, d2}
          end
          reaper.SendMIDIMessageToHardware = function() end
        """)
        mapper, _ = self.mapper()
        mapping = self.lua.eval("package.loaded.voice_map")
        voice = mapping.solo(65)
        solo = self.lua.table_from({
            "chan": 0, "msb": voice.msb, "lsb": voice.lsb,
            "prg": voice.prg, "solo": True, "name": "stale",
        })
        mapper.send_voices(0, self.lua.table_from([solo]))
        messages = [tuple(m.values()) for m in self.lua.globals().messages.values()]
        for expected in ((16, 176, 0, 63), (16, 176, 32, 4),
                         (16, 192, 2, 0), (16, 176, 7, 120),
                         (16, 176, 11, 127), (16, 176, 74, 64)):
            self.assertIn(expected, messages)
        self.assertEqual(solo.name, voice.name)
        self.lua.globals().settings.SoloVolume = "112"
        self.assertEqual(mapper.solo_volume(), 112)
        self.lua.globals().settings.SoloVolume = "999"
        self.assertEqual(mapper.solo_volume(), 127)
        self.lua.globals().settings.SoloVolume = "-1"
        self.assertEqual(mapper.solo_volume(), 0)

    def test_display_refresh_reads_section_without_sending_midi(self):
        self.lua.execute("reaper.ValidatePtr = function() return true end")
        mapper, driver = self.mapper()
        driver.sections = self.lua.eval("""{
          read = function(_, position)
            return {msb = 63, lsb = 4, prg = position < 2 and 2 or 15}
          end
        }""")
        voice = self.lua.table_from({"track": self.lua.table(), "name": "stale"})
        mapper.refresh_voice(voice, 0)
        self.assertTrue(voice.name.endswith("AltoVibLeg"))
        mapper.refresh_voice(voice, 3)
        self.assertTrue(voice.name.endswith("Sweet Flt"))
        voice.track, voice.msb, voice.lsb, voice.prg = None, 63, 99, 0
        mapper.refresh_voice(voice, 3)
        self.assertIn("Unknown MX voice", voice.name)

    def parse(self, track, declared_length=None):
        data = (b"MThd" + struct.pack(">IHHH", 6, 0, 1, 96) +
                b"MTrk" + struct.pack(">I", len(track) if declared_length is None else declared_length) + track + b"CASM")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.sty"
            path.write_bytes(data)
            return self.module(ROOT / "yamaha_style_manager" / "modules" / "sty_parser.lua").parse(str(path))

    def test_running_status_keeps_note_data_aligned(self):
        track = b"\x00\xff\x06\x06Main A\x00\x99\x24\x64\x10\x26\x50\x10\x89\x24\x00\x00\x26\x00\x00\xff\x2f\x00"
        ok, result = self.parse(track)
        self.assertTrue(ok, result)
        self.assertEqual(len(result.events), 4)
        self.assertEqual([e.data1 for e in result.events.values()], [36, 38, 36, 38])
        self.assertEqual(result.end_tick, 32)

    def test_short_end_of_track_length_is_reported(self):
        track = b"\x00\xff\x06\x06Main A\x00\xff\x2f\x00"
        ok, result = self.parse(track, len(track) - 1)
        self.assertTrue(ok, result)
        self.assertEqual(len(result.warnings), 1)

    def test_corrupt_data_is_rejected(self):
        ok, error = self.parse(b"\x00\x99\x24\xff\x00\xff\x2f\x00")
        self.assertFalse(ok)
        self.assertIn("invalid MIDI data", error)

    def test_all_gm_aliases_map_to_native_mx_voices(self):
        driver = self.module(SUITE / "lib" / "midi_yamaha_driver.lua")
        voices, arps = driver.init(str(SUITE / "data" / "Yamaha_MX49.reabank"),
                                   str(SUITE / "data" / "Yamaha_MX88_Arpeggios.csv"))
        self.assertGreater(voices, 1000)
        self.assertGreater(arps, 900)
        driver.init(str(SUITE / "data" / "Yamaha_MX49.reabank"), str(SUITE / "data" / "Yamaha_MX88_Arpeggios.csv"))
        self.assertEqual(len(driver.programs), voices)
        mapping = self.module(ROOT / "yamaha_style_manager" / "modules" / "voice_map.lua")
        mapping.configure(driver.programs)
        for program in range(128):
            voice = mapping.resolve(self.lua.table_from({"prg": program}), "solo")
            self.assertEqual(voice.msb, 63, (program, voice.name))
            self.assertLess(voice.lsb, 8)
        for program in (0, 8, 16, 24, 25, 32, 40, 48):
            voice = mapping.resolve(self.lua.table_from({"prg": program}), "drums")
            self.assertEqual((voice.msb, voice.lsb), (63, 32))
        preset = mapping.presets[20]
        self.assertEqual(mapping.solo(0, mapping.id(preset)).name, preset.name)

    def test_region_creation_returns_ids_and_saves_ownership(self):
        self.lua.execute("""
          saved = nil
          reaper = {
            SNM_SetIntConfigVar = function() end,
            ColorToNative = function() return 0 end,
            TimeMap2_QNToTime = function(_, qn) return qn end,
            AddProjectMarker2 = function() id = (id or 40) + 1; return id end,
            GetSetMediaTrackInfo_String = function(_, key, value) saved = value end
          }
        """)
        regions = self.module(ROOT / "yamaha_style_manager" / "modules" / "region_builder.lua")
        count, created = regions.create(self.lua.table_from([
            self.lua.table_from({"name": "Main A", "tick": 0}),
            self.lua.table_from({"name": "Main B", "tick": 96})]), 192, 96, self.lua.table())
        self.assertEqual(count, 2)
        self.assertEqual(self.lua.globals().saved, "41,42")
        self.assertEqual(created[2].finish, 2)


if __name__ == "__main__":
    unittest.main()
