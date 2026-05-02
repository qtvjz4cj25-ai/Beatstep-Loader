"""
gui.py — Beatstep-Loader
Tkinter GUI: load a MIDI file, review tracks, assign lanes, pick port, send.
"""

import tkinter as tk
from tkinter import ttk, filedialog, messagebox
import threading
import mido

from parser import parse_midi, TrackInfo
from assign import auto_assign
from sender import find_bsp_port, send_all, BSP_LANE_CHANNELS


ROLES = ["SEQ1 (Lead)", "SEQ2 (Bass)", "DRUM"]

BG        = "#1a1a2e"
BG2       = "#16213e"
ACCENT    = "#e94560"
FG        = "#eaeaea"
FG_DIM    = "#888899"
FONT_MONO = ("Courier New", 11)
FONT_UI   = ("Helvetica Neue", 11)
FONT_H    = ("Helvetica Neue", 13, "bold")


class BeatstepLoaderApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Beatstep Loader")
        self.configure(bg=BG)
        self.resizable(False, False)

        self.midi_path: str | None = None
        self.tracks: list[TrackInfo] = []
        self.assignment: dict[str, tk.StringVar] = {role: tk.StringVar(value="—") for role in ROLES}
        self.port_var = tk.StringVar(value="—")
        self.status_var = tk.StringVar(value="Load a MIDI file to begin.")

        self._build_ui()
        self._refresh_ports()

    # ------------------------------------------------------------------ #
    # UI Construction
    # ------------------------------------------------------------------ #

    def _build_ui(self):
        pad = {"padx": 16, "pady": 8}

        # ── Header ──
        header = tk.Frame(self, bg=ACCENT)
        header.pack(fill="x")
        tk.Label(header, text="BEATSTEP LOADER", font=("Helvetica Neue", 15, "bold"),
                 bg=ACCENT, fg="white", pady=8).pack()

        # ── File picker ──
        file_frame = tk.Frame(self, bg=BG2, pady=8)
        file_frame.pack(fill="x", padx=16, pady=(12, 4))

        tk.Label(file_frame, text="MIDI File", font=FONT_H, bg=BG2, fg=FG).grid(
            row=0, column=0, sticky="w", padx=10)
        self.file_label = tk.Label(file_frame, text="No file selected", font=FONT_MONO,
                                   bg=BG2, fg=FG_DIM, width=44, anchor="w")
        self.file_label.grid(row=0, column=1, padx=6)
        self._btn(file_frame, "Browse…", self._pick_file).grid(row=0, column=2, padx=8)

        # ── Track table ──
        table_frame = tk.Frame(self, bg=BG, pady=4)
        table_frame.pack(fill="x", padx=16, pady=4)

        tk.Label(table_frame, text="Tracks", font=FONT_H, bg=BG, fg=FG).pack(anchor="w")

        cols = ("#", "Name", "Ch", "Notes", "Note Range")
        self.tree = ttk.Treeview(table_frame, columns=cols, show="headings", height=7,
                                 selectmode="browse")
        widths = [30, 180, 60, 60, 220]
        for col, w in zip(cols, widths):
            self.tree.heading(col, text=col)
            self.tree.column(col, width=w, anchor="w")

        style = ttk.Style()
        style.theme_use("clam")
        style.configure("Treeview", background=BG2, foreground=FG, fieldbackground=BG2,
                        rowheight=22, font=FONT_MONO)
        style.configure("Treeview.Heading", background=BG, foreground=ACCENT,
                        font=("Helvetica Neue", 10, "bold"))
        style.map("Treeview", background=[("selected", ACCENT)], foreground=[("selected", "white")])

        self.tree.pack(fill="x")

        # ── Lane Assignment ──
        assign_frame = tk.Frame(self, bg=BG2, pady=10)
        assign_frame.pack(fill="x", padx=16, pady=4)

        tk.Label(assign_frame, text="Lane Assignment", font=FONT_H, bg=BG2, fg=FG).grid(
            row=0, column=0, columnspan=3, sticky="w", padx=10, pady=(0, 6))

        self.assign_menus: dict[str, ttk.Combobox] = {}
        for i, role in enumerate(ROLES):
            tk.Label(assign_frame, text=role, font=FONT_UI, bg=BG2, fg=FG, width=16,
                     anchor="w").grid(row=i+1, column=0, padx=10, pady=3, sticky="w")
            cb = ttk.Combobox(assign_frame, textvariable=self.assignment[role],
                              state="readonly", width=30, font=FONT_MONO)
            cb.grid(row=i+1, column=1, padx=6, pady=3)
            self.assign_menus[role] = cb

        self._btn(assign_frame, "Auto-Assign", self._auto_assign).grid(
            row=len(ROLES)+1, column=1, pady=(8, 2), sticky="w", padx=6)

        # ── MIDI Port ──
        port_frame = tk.Frame(self, bg=BG, pady=6)
        port_frame.pack(fill="x", padx=16, pady=4)

        tk.Label(port_frame, text="MIDI Output Port", font=FONT_H, bg=BG, fg=FG).grid(
            row=0, column=0, sticky="w")
        self.port_cb = ttk.Combobox(port_frame, textvariable=self.port_var,
                                    state="readonly", width=36, font=FONT_MONO)
        self.port_cb.grid(row=0, column=1, padx=8)
        self._btn(port_frame, "Refresh", self._refresh_ports).grid(row=0, column=2)

        # ── Send button + status ──
        bottom = tk.Frame(self, bg=BG, pady=10)
        bottom.pack(fill="x", padx=16)

        self.send_btn = self._btn(bottom, "SEND TO BEATSTEP PRO", self._send,
                                  font=("Helvetica Neue", 13, "bold"), bg=ACCENT,
                                  fg="white", padx=20, pady=8)
        self.send_btn.pack(pady=(0, 6))

        tk.Label(bottom, textvariable=self.status_var, font=FONT_UI, bg=BG,
                 fg=FG_DIM, wraplength=560).pack()

        # ── Log ──
        log_frame = tk.Frame(self, bg=BG)
        log_frame.pack(fill="both", padx=16, pady=(4, 12))

        tk.Label(log_frame, text="Log", font=FONT_H, bg=BG, fg=FG).pack(anchor="w")
        self.log_box = tk.Text(log_frame, height=6, bg=BG2, fg=FG_DIM, font=FONT_MONO,
                               state="disabled", relief="flat", bd=0)
        self.log_box.pack(fill="x")

    def _btn(self, parent, text, command, **kwargs):
        defaults = {"bg": "#2a2a4a", "fg": FG, "font": FONT_UI,
                    "relief": "flat", "cursor": "hand2",
                    "activebackground": ACCENT, "activeforeground": "white",
                    "padx": 10, "pady": 4}
        defaults.update(kwargs)
        return tk.Button(parent, text=text, command=command, **defaults)

    # ------------------------------------------------------------------ #
    # Actions
    # ------------------------------------------------------------------ #

    def _pick_file(self):
        path = filedialog.askopenfilename(
            title="Select MIDI File",
            filetypes=[("MIDI files", "*.mid *.midi"), ("All files", "*.*")]
        )
        if not path:
            return
        self.midi_path = path
        self.file_label.config(text=path.split("/")[-1], fg=FG)
        self._load_tracks()

    def _load_tracks(self):
        if not self.midi_path:
            return
        try:
            _, self.tracks = parse_midi(self.midi_path)
        except Exception as e:
            messagebox.showerror("Parse Error", str(e))
            return

        # Populate table
        for row in self.tree.get_children():
            self.tree.delete(row)
        for t in self.tracks:
            self.tree.insert("", "end", values=(
                t.index, t.name[:28], t.channels_str(),
                t.note_count, t.note_range_str()
            ))

        # Populate combobox options
        options = ["—"] + [f"{t.index}: {t.name}" for t in self.tracks]
        for cb in self.assign_menus.values():
            cb["values"] = options

        self._auto_assign()
        self._log(f"Loaded {len(self.tracks)} track(s) from {self.midi_path.split('/')[-1]}")
        self.status_var.set("Tracks loaded. Review assignment then send.")

    def _auto_assign(self):
        if not self.tracks:
            return
        suggested = auto_assign(self.tracks)
        for role in ROLES:
            track = suggested.get(role)
            if track:
                self.assignment[role].set(f"{track.index}: {track.name}")
            else:
                self.assignment[role].set("—")
        self._log("Auto-assignment applied.")

    def _refresh_ports(self):
        ports = mido.get_output_names()
        self.port_cb["values"] = ports if ports else ["(no ports found)"]

        # Auto-select BSP if found
        bsp = find_bsp_port()
        if bsp:
            self.port_var.set(bsp)
            self._log(f"BeatStep Pro detected: {bsp}")
        elif ports:
            self.port_var.set(ports[0])

    def _send(self):
        if not self.midi_path:
            messagebox.showwarning("No File", "Please load a MIDI file first.")
            return

        port = self.port_var.get()
        if not port or port == "(no ports found)":
            messagebox.showwarning("No Port", "Please select a MIDI output port.")
            return

        # Build assignment dict from UI selections
        assignment: dict[str, TrackInfo | None] = {}
        track_by_label = {f"{t.index}: {t.name}": t for t in self.tracks}
        for role in ROLES:
            val = self.assignment[role].get()
            assignment[role] = track_by_label.get(val)

        if all(v is None for v in assignment.values()):
            messagebox.showwarning("Nothing Assigned", "Assign at least one track before sending.")
            return

        self.send_btn.config(state="disabled")
        self.status_var.set("Sending…")
        self._log(f"Sending to {port}…")

        def _worker():
            try:
                send_all(self.midi_path, assignment, port)
                self.after(0, lambda: self._on_send_done(success=True))
            except Exception as e:
                self.after(0, lambda: self._on_send_done(success=False, error=str(e)))

        threading.Thread(target=_worker, daemon=True).start()

    def _on_send_done(self, success: bool, error: str = ""):
        self.send_btn.config(state="normal")
        if success:
            self.status_var.set("All tracks sent successfully.")
            self._log("Done.")
            messagebox.showinfo("Done", "All tracks sent to BeatStep Pro.")
        else:
            self.status_var.set(f"Error: {error}")
            self._log(f"Error: {error}")
            messagebox.showerror("Send Error", error)

    def _log(self, msg: str):
        self.log_box.config(state="normal")
        self.log_box.insert("end", f"› {msg}\n")
        self.log_box.see("end")
        self.log_box.config(state="disabled")


if __name__ == "__main__":
    app = BeatstepLoaderApp()
    app.mainloop()
