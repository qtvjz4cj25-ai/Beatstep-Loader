//
//  BeatstepModel.swift
//  Beatstep-Loader
//
//  View model and display models for the MIDI Decomposer MVP.
//

import Foundation
import Observation

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

    private func midiNoteName(_ note: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[note % 12])\((note / 12) - 1)"
    }

    init(from data: MIDITrackData) {
        index = data.index
        name = data.name
        channels = data.channels.sorted().map(Int.init)
        noteMin = data.noteMin.map(Int.init)
        noteMax = data.noteMax.map(Int.init)
        noteCount = data.noteCount
    }
}

@Observable
final class BeatstepModel {
    var fileURL: URL?
    var tracks: [MIDITrack] = []
    var midiDestinations: [CoreMIDIEngine.MIDIDestination] = []
    var selectedDestinationName = ""
    var selectedInspectorLane: TargetLane = .seq1
    var seq1Index: Int?
    var seq2Index: Int?
    var drumIndex: Int?
    var laneSettings: [TargetLane: LaneSettings] = [
        .seq1: .preset(for: .seq1),
        .seq2: .preset(for: .seq2),
        .drum: .preset(for: .drum),
    ]
    var capture = CaptureSettings()
    var volcaDrumProfile = VolcaDrumProfile()
    var detectedTempoBPM: Int?
    var logLines: [String] = []
    var isLoading = false
    var isSending = false

    let midi = CoreMIDIEngine()

    private var trackDataMap: [Int: MIDITrackData] = [:]
    private var ticksPerBeat: UInt16 = 480
    private var stopRequested = false

    var fileName: String { fileURL?.lastPathComponent ?? "No file selected" }

    var selectedDestination: CoreMIDIEngine.MIDIDestination? {
        midi.destination(named: selectedDestinationName, in: midiDestinations)
    }

    var selectedLaneSettings: LaneSettings {
        get { laneSettings[selectedInspectorLane] ?? .preset(for: selectedInspectorLane) }
        set { laneSettings[selectedInspectorLane] = newValue }
    }

    var selectedLaneTrackName: String {
        guard let track = track(for: selectedInspectorLane) else { return "No track assigned" }
        return track.name
    }

    var selectedLanePreviewCount: Int {
        guard let trackData = trackData(for: selectedInspectorLane) else { return 0 }
        return preprocess(trackData, lane: selectedInspectorLane).count
    }

    func loadFile(_ url: URL) async {
        fileURL = url
        isLoading = true
        log("Loading \(url.lastPathComponent)…")

        do {
            let (tpb, rawTracks) = try MIDIFileParser.parse(url)
            ticksPerBeat = tpb
            trackDataMap = Dictionary(uniqueKeysWithValues: rawTracks.map { ($0.index, $0) })
            tracks = rawTracks.map(MIDITrack.init(from:))
            detectedTempoBPM = extractTempoBPM(from: rawTracks) ?? Int(capture.bpm)
            if let detectedTempoBPM {
                capture.bpm = Double(detectedTempoBPM)
            }
            autoAssign(tracks)
            log("Loaded \(tracks.count) track(s) at \(tpb) ticks/beat")
        } catch {
            log("Error: \(error.localizedDescription)")
        }

        isLoading = false
    }

    func refreshPorts() {
        midiDestinations = midi.refreshDestinations()
        if selectedDestinationName.isEmpty {
            if let bsp = midi.bspDestination(in: midiDestinations) {
                selectedDestinationName = bsp.name
            } else if let first = midiDestinations.first {
                selectedDestinationName = first.name
            }
        }
        log("Found \(midiDestinations.count) MIDI destination(s)")
    }

    func stopSending() {
        stopRequested = true
    }

    func sendTestNote() async {
        guard let destination = selectedDestination else {
            log("Select a MIDI destination first")
            return
        }

        isSending = true
        let channel = selectedLaneSettings.bspRecordInputChannel
        log("Sending test note C4 on BSP record input channel \(channel) to \(destination.name)")
        midi.sendNoteOn(note: 60, velocity: 100, channel: channel, to: destination)
        try? await Task.sleep(nanoseconds: 300_000_000)
        midi.sendNoteOff(note: 60, channel: channel, to: destination)
        log("Test note complete")
        isSending = false
    }

    func sendLane(_ lane: TargetLane) async {
        guard let destination = selectedDestination else {
            log("Select a MIDI destination first")
            return
        }
        guard let trackData = trackData(for: lane) else {
            log("\(lane.rawValue): nothing assigned")
            return
        }
        guard let settings = laneSettings[lane] else {
            log("\(lane.rawValue): missing lane settings")
            return
        }
        guard capture.sendClock else {
            log("Capture blocked: BSP in USB Slave needs Send Clock enabled or it will not advance/record.")
            return
        }

        let notes = preprocess(trackData, lane: lane)
        guard !notes.isEmpty else {
            log("\(lane.rawValue): no playable notes after preprocessing")
            return
        }

        isSending = true
        stopRequested = false

        log("\(lane.rawValue) → \"\(trackData.name)\"  \(notes.count) notes, \(settings.patternLengthSteps) steps @ \(settings.grid.rawValue)")
        log("BSP record input channel: \(settings.bspRecordInputChannel)  intended playback/output channel: \(settings.intendedOutputChannel)")
        if capture.countIn != .off {
            log("Count-in: \(capture.countIn.rawValue)")
        }
        if !capture.sendStartStop {
            log("Warning: Send Start/Stop is off. BSP may stay armed but not actually run unless you start transport manually.")
        }
        if lane == .drum {
            log("Volca Drum mode: \(volcaDrumProfile.mode.rawValue)")
        }

        await midi.captureToLane(
            notes,
            to: destination,
            outputChannel: settings.bspRecordInputChannel,
            gridTicks: UInt64(Double(ticksPerBeat) / settings.grid.stepsPerQuarterNote),
            ticksPerBeat: ticksPerBeat,
            settings: capture,
            sendNoteOffs: lane != .drum,
            stopSignal: { self.stopRequested }
        )

        log("\(lane.rawValue): done")
        isSending = false
    }

    func previewAssignedTracks() async {
        guard let destination = selectedDestination else {
            log("Select a MIDI destination first")
            return
        }

        isSending = true
        log("Previewing assigned tracks on \(destination.name)")

        await withTaskGroup(of: Void.self) { group in
            for lane in TargetLane.allCases {
                guard let trackData = trackData(for: lane),
                      let settings = laneSettings[lane] else { continue }
                let tpb = ticksPerBeat
                group.addTask {
                    await self.midi.sendTrack(trackData, to: destination, outputChannel: settings.intendedOutputChannel, ticksPerBeat: tpb)
                }
            }
        }

        isSending = false
        log("Preview complete")
    }

    func autoAssign(_ tracks: [MIDITrack]) {
        var pool = tracks.filter { $0.noteCount > 0 }
        seq1Index = nil
        seq2Index = nil
        drumIndex = nil

        if let drumTrack = pool.first(where: { $0.channels.contains(9) }) {
            drumIndex = drumTrack.index
            pool.removeAll { $0.id == drumTrack.id }
        }

        if let bassTrack = pool.min(by: { avgNote($0) < avgNote($1) }) {
            seq1Index = bassTrack.index
            pool.removeAll { $0.id == bassTrack.id }
        }

        if let leadTrack = pool.max(by: { avgNote($0) < avgNote($1) }) {
            seq2Index = leadTrack.index
            pool.removeAll { $0.id == leadTrack.id }
        }

        if drumIndex == nil, let remaining = pool.first {
            drumIndex = remaining.index
        }
    }

    func track(for lane: TargetLane) -> MIDITrack? {
        guard let index = laneIndex(lane) else { return nil }
        return tracks.first(where: { $0.index == index })
    }

    func updateBSPRecordInputChannel(for lane: TargetLane, channel: UInt8) {
        guard var settings = laneSettings[lane] else { return }
        settings.bspRecordInputChannel = min(max(channel, 1), 16)
        laneSettings[lane] = settings
    }

    func updateIntendedOutputChannel(for lane: TargetLane, channel: UInt8) {
        guard var settings = laneSettings[lane] else { return }
        settings.intendedOutputChannel = min(max(channel, 1), 16)
        laneSettings[lane] = settings
    }

    func updatePatternLength(for lane: TargetLane, steps: Int) {
        guard var settings = laneSettings[lane] else { return }
        settings.patternLengthSteps = steps
        laneSettings[lane] = settings
    }

    func log(_ message: String) {
        logLines.append(message)
    }

    private func laneIndex(_ lane: TargetLane) -> Int? {
        switch lane {
        case .seq1: return seq1Index
        case .seq2: return seq2Index
        case .drum: return drumIndex
        }
    }

    private func trackData(for lane: TargetLane) -> MIDITrackData? {
        guard let index = laneIndex(lane) else { return nil }
        return trackDataMap[index]
    }

    private func preprocess(_ trackData: MIDITrackData, lane: TargetLane) -> [QuantizedNote] {
        guard let settings = laneSettings[lane] else { return [] }
        return MIDIPreprocessor(lane: settings, ticksPerBeat: ticksPerBeat).process(trackData)
    }

    private func avgNote(_ track: MIDITrack) -> Int {
        ((track.noteMin ?? 0) + (track.noteMax ?? 0)) / 2
    }

    private func extractTempoBPM(from tracks: [MIDITrackData]) -> Int? {
        for track in tracks {
            for event in track.events where event.isMeta && event.metaType == 0x51 && event.metaPayload.count >= 3 {
                let tempo = (UInt32(event.metaPayload[0]) << 16)
                    | (UInt32(event.metaPayload[1]) << 8)
                    | UInt32(event.metaPayload[2])
                guard tempo > 0 else { continue }
                return Int(round(60_000_000.0 / Double(tempo)))
            }
        }
        return nil
    }
}
