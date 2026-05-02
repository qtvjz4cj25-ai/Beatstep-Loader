"""
sender.py — Beatstep-Loader
Sends assigned MIDI tracks to the BeatStep Pro via the correct port/channel.
Supports both interactive CLI mode and non-interactive mode (used by the Swift GUI).
"""

import mido
import time
from parser import TrackInfo


# BSP MIDI port names (partial match)
BSP_PORT_HINTS = ["BeatStep Pro", "Arturia BeatStep", "beatstep"]

# Output channels per BSP lane (0-indexed internally)
BSP_LANE_CHANNELS = {
    "SEQ1 (Lead)": 0,   # MIDI ch 1
    "SEQ2 (Bass)": 1,   # MIDI ch 2
    "DRUM": 9,          # MIDI ch 10
}


def find_bsp_port() -> str | None:
    available = mido.get_output_names()
    for port in available:
        for hint in BSP_PORT_HINTS:
            if hint.lower() in port.lower():
                return port
    return None


def list_ports():
    ports = mido.get_output_names()
    if not ports:
        print("No MIDI output ports found.")
    else:
        print("\nAvailable MIDI output ports:")
        for i, p in enumerate(ports):
            print(f"  {i}: {p}")
    return ports


def choose_port() -> str | None:
    ports = list_ports()
    if not ports:
        return None
    raw = input("\nEnter port number to use > ").strip()
    try:
        return ports[int(raw)]
    except (ValueError, IndexError):
        print("Invalid selection.")
        return None


def get_output_port() -> str | None:
    auto = find_bsp_port()
    if auto:
        print(f"\nBeatStep Pro detected: \"{auto}\"")
        ans = input("Use this port? [Y/n] > ").strip().lower()
        if ans in ("", "y", "yes"):
            return auto
    else:
        print("\nBeatStep Pro not auto-detected.")
    return choose_port()


def send_track(
    midi_path: str,
    track_info: TrackInfo,
    port_name: str,
    out_channel: int,
    tempo_override: int | None = None,
):
    mid = mido.MidiFile(midi_path)
    track = mid.tracks[track_info.index]

    print(f"  Sending \"{track_info.name}\" → {port_name}  (ch {out_channel + 1})")

    with mido.open_output(port_name) as port:
        tempo = tempo_override or 500000  # default 120 BPM
        ticks_per_beat = mid.ticks_per_beat

        for msg in track:
            if msg.time > 0:
                time.sleep(mido.tick2second(msg.time, ticks_per_beat, tempo))

            if msg.is_meta:
                if msg.type == "set_tempo":
                    tempo = msg.tempo
                continue

            if hasattr(msg, "channel"):
                msg = msg.copy(channel=out_channel)

            port.send(msg)

    print(f"  Done: \"{track_info.name}\"")


def send_all(
    midi_path: str,
    assignment: dict[str, TrackInfo | None],
    port_name: str,
):
    print(f"\n=== Sending to \"{port_name}\" ===")

    for role, track_info in assignment.items():
        if track_info is None:
            print(f"\n  {role}: (skipped — no track assigned)")
            continue
        out_channel = BSP_LANE_CHANNELS[role]
        send_track(midi_path, track_info, port_name, out_channel)

    print("\n=== All tracks sent. ===\n")


if __name__ == "__main__":
    import argparse
    from parser import parse_midi
    from assign import run as assign_run

    parser = argparse.ArgumentParser(
        description="Send MIDI tracks to the BeatStep Pro."
    )
    parser.add_argument("midi_file", help="Path to the .mid file")
    parser.add_argument("port", nargs="?", default=None,
                        help="MIDI port name (non-interactive mode)")
    parser.add_argument("--seq1", type=int, default=None, metavar="INDEX",
                        help="Track index for SEQ1 (Lead)")
    parser.add_argument("--seq2", type=int, default=None, metavar="INDEX",
                        help="Track index for SEQ2 (Bass)")
    parser.add_argument("--drum", type=int, default=None, metavar="INDEX",
                        help="Track index for DRUM")
    args = parser.parse_args()

    _, tracks = parse_midi(args.midi_file)
    track_by_idx = {t.index: t for t in tracks}

    if args.port:
        # Non-interactive mode — all args supplied (called from GUI)
        assignment = {
            "SEQ1 (Lead)": track_by_idx.get(args.seq1),
            "SEQ2 (Bass)": track_by_idx.get(args.seq2),
            "DRUM":        track_by_idx.get(args.drum),
        }
        port = args.port
    else:
        # Interactive mode — original flow
        assignment = assign_run(args.midi_file)
        port = get_output_port()
        if not port:
            print("No MIDI port selected. Aborting.")
            exit(1)

    send_all(args.midi_file, assignment, port)
