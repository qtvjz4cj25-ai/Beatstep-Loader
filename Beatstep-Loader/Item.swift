//
//  BeatstepModel.swift
//  Beatstep-Loader
//
//  Display models + ViewModel.
//  Uses native Swift MIDIEngine — no Python required.
//

import Foundation
import Observation

// MARK: - Display models

struct MIDITrack: Identifiable, Hashable {
    var id: Int { index }
    let index: Int
    let name: String
    let channels: [Int]
    let noteMin: Int?
    let noteMax: Int?
    let noteCount: Int

    var channelStr: String {
        channels.isEmpty ? "—" : channels.map { "\($0 + 1)" }.joined(separator: ", ")
    }

    var noteRangeStr: String {
        guard let lo = noteMin, let hi = noteMax else { return "—" }
        return "\(midiNoteName(lo)) – \(midiNoteName(hi))"
    }

    private func midiNoteName(_ n: Int) -> String {
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        return "\(names[n % 12])\((n / 12) - 1)"
    }

    init(from data: MIDITrackData) {
        self.index     = data.index
        self.name      = data.name
        self.channels  = data.channels.sorted().map { Int($0) }
        self.noteMin   = data.noteMin.map { Int($0) }
        self.noteMax   = data.noteMax.map { Int($0) }
        self.noteCount = data.noteCount
    }
}

// MARK: - ViewModel

@Observable
final class BeatstepModel {

    // Display
    var fileURL: URL?
    var tracks: [MIDITrack] = []
    var seq1Index: Int? = nil
    var seq2Index: Int? = nil
    var drumIndex: Int? = nil
    var logLines: [String] = []
    var isLoading  = false
    var isSending  = false

    // Capture settings (drives quantize, clock, loop, count-in)
    var capture = CaptureSettings()

    // MIDI engine
    let midi = CoreMIDIEngine()

    // Raw track data for playback
    private var trackDataMap: [Int: MIDITrackData] = [:]
    private var ticksPerBeat: UInt16 = 480

    // Loop stop flag
    private var stopRequested = false

    var fileName: String { fileURL?.lastPathComponent ?? "No file selected" }

    // BSP output channels (0-indexed)
    private let bspChannels: [String: UInt8] = [
        "SEQ1": 0,  // MIDI ch 1
        "SEQ2": 1,  // MIDI ch 2
        "DRUM": 9,  // MIDI ch 10
    ]

    // MARK: Actions

    func loadFile(_ url: URL) async {
        fileURL  = url
        isLoading = true
        log("Loading \(url.lastPathComponent)…")
        do {
            let (tpb, rawTracks) = try MIDIFileParser.parse(url)
            ticksPerBeat = tpb
            trackDataMap = Dictionary(uniqueKeysWithValues: rawTracks.map { ($0.index, $0) })
            tracks = rawTracks.map { MIDITrack(from: $0) }
            autoAssign(tracks)
            log("Loaded \(tracks.count) track(s)  (\(tpb) ticks/beat)")
        } catch {
            log("Error: \(error.localizedDescription)")
        }
        isLoading = false
    }

    func refreshPorts() {
        midi.refreshDestinations()
        if let bsp = midi.bspDestination() {
            log("BeatStep Pro detected: \(bsp.name)")
        } else {
            log("Found \(midi.destinations.count) MIDI port(s).")
        }
    }

    func stopSending() {
        stopRequested = true
    }

    /// Send a single lane — quantized, monophonic, with clock + count-in.
    func sendLane(_ lane: String, to destName: String) async {
        guard let dest = midi.destinations.first(where: { $0.name == destName }),
              let idx  = laneIndex(lane),
              let td   = trackDataMap[idx]
        else { log("\(lane): nothing to send"); return }

        isSending     = true
        stopRequested = false

        let notes = preprocess(td)
        log("\(lane) → \"\(td.name)\"  \(notes.count) steps  \(capture.patternSteps)×1/\(capture.gridDivision)")
        if capture.countIn { log("Count-in: 1 bar…") }
        if capture.loop     { log("Looping — press Stop to end.") }

        await midi.captureToLane(notes, to: dest,
                                 outputChannel: bspChannels[lane] ?? 0,
                                 ticksPerBeat: ticksPerBeat,
                                 settings: capture,
                                 stopSignal: { self.stopRequested })
        log("\(lane): done")
        isSending = false
    }

    /// Send all lanes simultaneously (for preview/playback, no clock).
    func sendAllParallel(to destName: String) async {
        guard let dest = midi.destinations.first(where: { $0.name == destName }) else {
            log("Port not found: \(destName)"); return
        }
        isSending = true
        log("Sending all lanes in parallel to \"\(dest.name)\"…")

        await withTaskGroup(of: Void.self) { group in
            for lane in ["SEQ1", "SEQ2", "DRUM"] {
                guard let idx = laneIndex(lane), let td = trackDataMap[idx] else { continue }
                let ch  = bspChannels[lane] ?? 0
                let tpb = ticksPerBeat
                group.addTask {
                    await self.midi.sendTrack(td, to: dest, outputChannel: ch, ticksPerBeat: tpb)
                }
                log("  \(lane) → Track \(idx): \"\(td.name)\"")
            }
        }
        isSending = false
        log("All lanes sent.")
    }

    // MARK: Auto-assign

    func autoAssign(_ tracks: [MIDITrack]) {
        var pool = tracks
        seq1Index = nil; seq2Index = nil; drumIndex = nil

        // DRUM: ch10 (idx 9), or GM drum note range 35–81
        if let t = pool.first(where: { $0.channels.contains(9) }) {
            drumIndex = t.index; pool.removeAll { $0.id == t.id }
        } else if let t = pool.first(where: {
            ($0.noteMin ?? 0) >= 35 && ($0.noteMax ?? 127) <= 81
        }) {
            drumIndex = t.index; pool.removeAll { $0.id == t.id }
        }

        // Bass: lowest average note
        let noteTracks = pool.filter { $0.noteMin != nil }
        if let t = noteTracks.min(by: { avgNote($0) < avgNote($1) }) {
            seq2Index = t.index; pool.removeAll { $0.id == t.id }
        }

        // Lead: first remaining
        seq1Index = pool.first?.index
    }

    // MARK: Private

    private func preprocess(_ td: MIDITrackData) -> [QuantizedNote] {
        MIDIPreprocessor(settings: capture, ticksPerBeat: ticksPerBeat).process(td)
    }

    private func laneIndex(_ lane: String) -> Int? {
        switch lane {
        case "SEQ1": return seq1Index
        case "SEQ2": return seq2Index
        case "DRUM": return drumIndex
        default:     return nil
        }
    }

    func log(_ msg: String) { logLines.append(msg) }

    private func avgNote(_ t: MIDITrack) -> Int {
        ((t.noteMin ?? 0) + (t.noteMax ?? 0)) / 2
    }
}
