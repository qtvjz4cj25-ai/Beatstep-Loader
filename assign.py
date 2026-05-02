"""
assign.py — Beatstep-Loader
Auto-detects track roles (DRUM / Lead / Bass) then lets you confirm or reassign.
"""

from parser import TrackInfo, parse_midi, print_summary, note_name

ROLES = ["SEQ1 (Lead)", "SEQ2 (Bass)", "DRUM"]
DRUM_CHANNEL = 9  # MIDI ch 10 is index 9


def auto_assign(tracks: list[TrackInfo]) -> dict[str, TrackInfo | None]:
    """
    Heuristic assignment:
    - DRUM: any track on ch10, or avg note in the General MIDI drum range (35-81)
    - SEQ2 (Bass): lowest average note among remaining tracks
    - SEQ1 (Lead): whatever is left
    """
    unassigned = list(tracks)
    assignment: dict[str, TrackInfo | None] = {
        "DRUM": None,
        "SEQ2 (Bass)": None,
        "SEQ1 (Lead)": None,
    }

    # Step 1: find drum track
    for t in unassigned:
        if DRUM_CHANNEL in t.channels:
            assignment["DRUM"] = t
            unassigned.remove(t)
            break

    # Fallback: if no ch10, pick track whose notes are mostly in GM drum range
    if assignment["DRUM"] is None:
        for t in unassigned:
            if t.note_min is not None and t.note_min >= 35 and t.note_max <= 81:
                assignment["DRUM"] = t
                unassigned.remove(t)
                break

    # Step 2: bass = lowest average note among remaining note-bearing tracks
    note_tracks = [t for t in unassigned if t.note_min is not None]
    if note_tracks:
        bass = min(note_tracks, key=lambda t: (t.note_min + t.note_max) / 2)
        assignment["SEQ2 (Bass)"] = bass
        unassigned.remove(bass)

    # Step 3: lead = first remaining track with notes, else first track
    if unassigned:
        assignment["SEQ1 (Lead)"] = unassigned[0]

    return assignment


def display_assignment(assignment: dict[str, TrackInfo | None]):
    print("\n--- Suggested Assignment ---")
    for role, track in assignment.items():
        if track:
            print(f"  {role:<16} → Track {track.index}: \"{track.name}\"  "
                  f"[ch: {track.channels_str()}  notes: {track.note_count}  range: {track.note_range_str()}]")
        else:
            print(f"  {role:<16} → (none)")
    print()


def interactive_reassign(
    assignment: dict[str, TrackInfo | None],
    all_tracks: list[TrackInfo]
) -> dict[str, TrackInfo | None]:
    """Let the user confirm or override each role assignment."""

    print("Press Enter to accept a suggestion, or enter a track number to reassign.")
    print("Enter 'x' to leave a slot empty.\n")

    # Build index lookup
    track_by_index = {t.index: t for t in all_tracks}

    for role in list(assignment.keys()):
        current = assignment[role]
        current_str = f"Track {current.index} \"{current.name}\"" if current else "(none)"
        raw = input(f"  {role:<16} [{current_str}] > ").strip()

        if raw == "":
            pass  # keep suggestion
        elif raw.lower() == "x":
            assignment[role] = None
        else:
            try:
                idx = int(raw)
                if idx in track_by_index:
                    assignment[role] = track_by_index[idx]
                else:
                    print(f"    No track {idx}, keeping current.")
            except ValueError:
                print("    Invalid input, keeping current.")

    return assignment


def confirm_assignment(assignment: dict[str, TrackInfo | None]) -> bool:
    display_assignment(assignment)
    ans = input("Confirm this assignment? [Y/n] > ").strip().lower()
    return ans in ("", "y", "yes")


def run(midi_path: str) -> dict[str, TrackInfo | None]:
    mid, tracks = parse_midi(midi_path)
    print_summary(mid, tracks)

    assignment = auto_assign(tracks)
    display_assignment(assignment)

    ans = input("Accept auto-assignment? [Y/n] > ").strip().lower()
    if ans not in ("", "y", "yes"):
        assignment = interactive_reassign(assignment, tracks)

    while not confirm_assignment(assignment):
        assignment = interactive_reassign(assignment, tracks)

    print("\nFinal assignment locked in:")
    display_assignment(assignment)
    return assignment


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(
        description="Assign MIDI tracks to BSP lanes (SEQ1/SEQ2/DRUM)."
    )
    parser.add_argument("midi_file", help="Path to the .mid file")
    args = parser.parse_args()

    run(args.midi_file)
