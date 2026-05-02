"""
parser.py — Beatstep-Loader
Reads a .mid file and extracts track info: name, channel, note range, message count.
Supports --json flag for machine-readable output (used by the Swift GUI).
"""

import mido
import argparse
import json
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class TrackInfo:
    index: int
    name: str
    channels: set = field(default_factory=set)
    note_min: Optional[int] = None
    note_max: Optional[int] = None
    note_count: int = 0
    message_count: int = 0

    def record_note(self, note: int):
        self.note_count += 1
        self.note_min = note if self.note_min is None else min(self.note_min, note)
        self.note_max = note if self.note_max is None else max(self.note_max, note)

    def note_range_str(self) -> str:
        if self.note_min is None:
            return "—"
        return f"{note_name(self.note_min)} ({self.note_min}) – {note_name(self.note_max)} ({self.note_max})"

    def channels_str(self) -> str:
        if not self.channels:
            return "—"
        return ", ".join(str(ch + 1) for ch in sorted(self.channels))

    def to_dict(self) -> dict:
        return {
            "index": self.index,
            "name": self.name,
            "channels": sorted(list(self.channels)),
            "noteMin": self.note_min,
            "noteMax": self.note_max,
            "noteCount": self.note_count,
        }


def note_name(midi_note: int) -> str:
    names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    octave = (midi_note // 12) - 1
    return f"{names[midi_note % 12]}{octave}"


def parse_midi(path: str) -> tuple[mido.MidiFile, list[TrackInfo]]:
    mid = mido.MidiFile(path)
    tracks = []

    for i, track in enumerate(mid.tracks):
        info = TrackInfo(index=i, name=track.name or f"Track {i}")
        for msg in track:
            info.message_count += 1
            if msg.type in ("note_on", "note_off"):
                info.channels.add(msg.channel)
                if msg.type == "note_on" and msg.velocity > 0:
                    info.record_note(msg.note)
        tracks.append(info)

    return mid, tracks


def print_summary(mid: mido.MidiFile, tracks: list[TrackInfo]):
    ttype = ["type 0 (single)", "type 1 (multi-track)", "type 2 (multi-song)"][mid.type]
    print(f"\nFile type : {ttype}")
    print(f"Tempo map : {mid.ticks_per_beat} ticks/beat")
    print(f"Tracks    : {len(tracks)}\n")

    header = f"{'#':<4} {'Name':<24} {'Ch':<10} {'Notes':<8} {'Note Range'}"
    print(header)
    print("-" * len(header))

    for t in tracks:
        print(
            f"{t.index:<4} {t.name[:23]:<24} {t.channels_str():<10} "
            f"{t.note_count:<8} {t.note_range_str()}"
        )
    print()


def main():
    parser = argparse.ArgumentParser(
        description="Parse a MIDI file and display track information."
    )
    parser.add_argument("midi_file", help="Path to the .mid file")
    parser.add_argument("--json", action="store_true", help="Output as JSON (used by GUI)")
    args = parser.parse_args()

    mid, tracks = parse_midi(args.midi_file)

    if args.json:
        output = {
            "type": mid.type,
            "ticksPerBeat": mid.ticks_per_beat,
            "tracks": [t.to_dict() for t in tracks],
        }
        print(json.dumps(output))
    else:
        print_summary(mid, tracks)


if __name__ == "__main__":
    main()
