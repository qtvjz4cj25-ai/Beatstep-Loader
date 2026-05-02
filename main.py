"""
main.py — Beatstep-Loader
Entry point. Ties parser → assign → sender into one clean run.
"""

import argparse
import sys
from parser import parse_midi, print_summary
from assign import auto_assign, display_assignment, interactive_reassign, confirm_assignment
from sender import get_output_port, send_all


def run(midi_path: str):
    print(f"\nLoading: {midi_path}")

    # 1. Parse
    mid, tracks = parse_midi(midi_path)
    print_summary(mid, tracks)

    # 2. Auto-assign
    assignment = auto_assign(tracks)
    display_assignment(assignment)

    # 3. Confirm or override
    ans = input("Accept auto-assignment? [Y/n] > ").strip().lower()
    if ans not in ("", "y", "yes"):
        assignment = interactive_reassign(assignment, tracks)

    while not confirm_assignment(assignment):
        assignment = interactive_reassign(assignment, tracks)

    # 4. Pick MIDI port
    port = get_output_port()
    if not port:
        print("No MIDI port selected. Aborting.")
        sys.exit(1)

    # 5. Send
    send_all(midi_path, assignment, port)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Beatstep-Loader: load a MIDI file into your BeatStep Pro."
    )
    parser.add_argument("midi_file", help="Path to the .mid file")
    args = parser.parse_args()

    run(args.midi_file)
