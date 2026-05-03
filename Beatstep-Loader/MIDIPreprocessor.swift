//
//  MIDIPreprocessor.swift
//  Beatstep-Loader
//
//  Converts raw MIDI track data into BSP-ready monophonic step sequences.
//  Pipeline: extract note pairs → quantize → clip to pattern → mono reduce → resolve overlaps
//

import Foundation

enum TargetLane: String, CaseIterable, Identifiable {
    case seq1 = "SEQ 1"
    case seq2 = "SEQ 2"
    case drum = "DRUM"

    var id: String { rawValue }

    var defaultChannel: UInt8 {
        switch self {
        case .seq1: return 1
        case .seq2: return 2
        case .drum: return 10
        }
    }

    var defaultMonoRule: MonoPriorityRule {
        switch self {
        case .seq1: return .lowestNote
        case .seq2: return .highestNote
        case .drum: return .newestNote
        }
    }
}

enum MonoPriorityRule: String, CaseIterable, Identifiable {
    case highestNote = "Highest Note"
    case lowestNote = "Lowest Note"
    case newestNote = "Newest Note"
    case longestNote = "Longest Note"

    var id: String { rawValue }
}

enum GridResolution: String, CaseIterable, Identifiable {
    case eighth = "1/8"
    case sixteenth = "1/16"
    case thirtySecond = "1/32"

    var id: String { rawValue }

    var stepsPerQuarterNote: Double {
        switch self {
        case .eighth: return 2
        case .sixteenth: return 4
        case .thirtySecond: return 8
        }
    }

    var divisionValue: Int {
        switch self {
        case .eighth: return 8
        case .sixteenth: return 16
        case .thirtySecond: return 32
        }
    }
}

enum CountInMode: String, CaseIterable, Identifiable {
    case off = "Off"
    case oneBar = "1 Bar"
    case twoBars = "2 Bars"

    var id: String { rawValue }

    var bars: UInt64 {
        switch self {
        case .off: return 0
        case .oneBar: return 1
        case .twoBars: return 2
        }
    }
}

enum VelocityMode: String, CaseIterable, Identifiable {
    case preserve = "Preserve"
    case normalized = "Normalize"

    var id: String { rawValue }
}

enum VolcaDrumMIDIMode: String, CaseIterable, Identifiable {
    case singleChannel = "Single Channel"
    case splitChannel = "Split Channel / Factory Default"

    var id: String { rawValue }
}

struct MIDINoteEvent: Identifiable, Hashable {
    let id = UUID()
    var note: UInt8
    var velocity: UInt8
    var startBeat: Double
    var durationBeats: Double
    var channel: UInt8
    var trackName: String?
}

struct MIDITrackInfo: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var channel: UInt8?
    var notes: [MIDINoteEvent]
}

struct BSPPatternLane: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var target: TargetLane
    var bspRecordInputChannel: UInt8
    var intendedOutputChannel: UInt8
    var lengthSteps: Int
    var grid: GridResolution
    var notes: [MIDINoteEvent]
}

struct VolcaDrumPartMapping: Identifiable, Hashable {
    let id = UUID()
    var partNumber: Int
    var sourceNote: UInt8
    var outputNote: UInt8
    var outputChannel: UInt8
}

struct VolcaDrumProfile: Hashable {
    var mode: VolcaDrumMIDIMode = .singleChannel
    var singleChannel: UInt8 = 10
    var rxShortMessageEnabled = false
    var clockSourceAuto = true
    var partMappings: [VolcaDrumPartMapping] = [
        VolcaDrumPartMapping(partNumber: 1, sourceNote: 36, outputNote: 36, outputChannel: 1),
        VolcaDrumPartMapping(partNumber: 2, sourceNote: 38, outputNote: 38, outputChannel: 2),
        VolcaDrumPartMapping(partNumber: 3, sourceNote: 42, outputNote: 42, outputChannel: 3),
        VolcaDrumPartMapping(partNumber: 4, sourceNote: 46, outputNote: 46, outputChannel: 4),
        VolcaDrumPartMapping(partNumber: 5, sourceNote: 45, outputNote: 45, outputChannel: 5),
        VolcaDrumPartMapping(partNumber: 6, sourceNote: 39, outputNote: 39, outputChannel: 6),
    ]
}

struct LaneSettings: Identifiable, Hashable {
    let id = UUID()
    var target: TargetLane
    var bspRecordInputChannel: UInt8
    var intendedOutputChannel: UInt8
    var patternLengthSteps: Int
    var grid: GridResolution
    var monoRule: MonoPriorityRule
    var velocityMode: VelocityMode

    static func preset(for target: TargetLane) -> LaneSettings {
        LaneSettings(
            target: target,
            bspRecordInputChannel: target.defaultChannel,
            intendedOutputChannel: target.defaultChannel,
            patternLengthSteps: 16,
            grid: .sixteenth,
            monoRule: target.defaultMonoRule,
            velocityMode: .preserve
        )
    }
}

// MARK: - Settings

struct CaptureSettings {
    var bpm: Double = 120
    var countIn: CountInMode = .oneBar
    var loop = false
    var sendClock = true
    var sendStartStop = true

    var nsPerBeat: UInt64 { UInt64(60_000_000_000.0 / bpm) }
    var nsPerPulse: UInt64 { nsPerBeat / 24 }
    var beatsPerBar: UInt64 { 4 }
    var countInBeats: UInt64 { countIn.bars * beatsPerBar }
    var countInNs: UInt64 { nsPerBeat * countInBeats }
}

// MARK: - Processed note

struct QuantizedNote {
    let startTick:    UInt64
    let durationTicks: UInt64
    let note:         UInt8
    let velocity:     UInt8
}

// MARK: - Preprocessor

struct MIDIPreprocessor {

    let lane: LaneSettings
    let ticksPerBeat: UInt16

    private var gridTicks: UInt64 {
        UInt64(Double(ticksPerBeat) / lane.grid.stepsPerQuarterNote)
    }

    private var patternTicks: UInt64 {
        gridTicks * UInt64(lane.patternLengthSteps)
    }

    // MARK: Main pipeline

    func process(_ trackData: MIDITrackData) -> [QuantizedNote] {
        let pairs = extractNotePairs(trackData)
        let quantized = pairs.map { quantize($0) }
        let clipped = clip(quantized)

        if lane.target == .drum {
            return clipped.map { drumNote in
                QuantizedNote(
                    startTick: drumNote.startTick,
                    durationTicks: gridTicks,
                    note: drumNote.note,
                    velocity: normalizeVelocityIfNeeded(drumNote.velocity)
                )
            }
        }

        let mono = reduceMono(clipped)
        return resolveOverlaps(mono)
    }

    // MARK: Step 1 — extract note pairs

    private struct RawNote {
        var startTick: UInt64
        var durationTicks: UInt64
        var note: UInt8
        var velocity: UInt8
    }

    private func extractNotePairs(_ track: MIDITrackData) -> [RawNote] {
        var active = [UInt8: (tick: UInt64, vel: UInt8)]()   // note → (on-tick, velocity)
        var pairs  = [RawNote]()

        for event in track.events {
            guard !event.isMeta else { continue }
            let type = event.statusByte & 0xF0

            if type == 0x90 && event.data2 > 0 {                          // note-on
                active[event.data1] = (event.absoluteTick, event.data2)

            } else if type == 0x80 || (type == 0x90 && event.data2 == 0) { // note-off
                if let start = active[event.data1] {
                    let dur = event.absoluteTick > start.tick
                        ? event.absoluteTick - start.tick
                        : gridTicks
                    pairs.append(RawNote(startTick: start.tick, durationTicks: dur,
                                        note: event.data1, velocity: start.vel))
                    active.removeValue(forKey: event.data1)
                }
            }
        }
        // Close any notes still open at end
        for (pitch, start) in active {
            pairs.append(RawNote(startTick: start.tick, durationTicks: gridTicks,
                                 note: pitch, velocity: start.vel))
        }
        return pairs.sorted { $0.startTick < $1.startTick }
    }

    // MARK: Step 2 — quantize to grid

    private func quantize(_ raw: RawNote) -> RawNote {
        let half         = gridTicks / 2
        let qStart       = ((raw.startTick + half) / gridTicks) * gridTicks
        let qDur         = max(((raw.durationTicks + half) / gridTicks) * gridTicks, gridTicks)
        return RawNote(startTick: qStart, durationTicks: qDur,
                       note: raw.note, velocity: raw.velocity)
    }

    // MARK: Step 3 — clip to pattern window

    private func clip(_ notes: [RawNote]) -> [RawNote] {
        notes.compactMap { n in
            guard n.startTick < patternTicks else { return nil }
            let clippedDur = min(n.durationTicks, patternTicks - n.startTick)
            return RawNote(startTick: n.startTick, durationTicks: max(clippedDur, gridTicks),
                           note: n.note, velocity: n.velocity)
        }
    }

    // MARK: Step 4 — monophonic reduction

    private func reduceMono(_ notes: [RawNote]) -> [RawNote] {
        // Group notes that start at the same quantized tick
        var byTick = [UInt64: [RawNote]]()
        for n in notes { byTick[n.startTick, default: []].append(n) }

        return byTick.sorted { $0.key < $1.key }.map { (_, group) in
            switch lane.monoRule {
            case .highestNote:
                return group.max(by: { $0.note < $1.note })!
            case .lowestNote:
                return group.min(by: { $0.note < $1.note })!
            case .newestNote:
                return group.max(by: { $0.startTick < $1.startTick })!
            case .longestNote:
                return group.max(by: { $0.durationTicks < $1.durationTicks })!
            }
        }
    }

    // MARK: Step 5 — resolve overlaps (truncate preceding note)

    private func resolveOverlaps(_ notes: [RawNote]) -> [QuantizedNote] {
        var result = [QuantizedNote]()
        let sorted = notes.sorted { $0.startTick < $1.startTick }

        for i in sorted.indices {
            let cur  = sorted[i]
            var dur  = cur.durationTicks
            if i + 1 < sorted.count {
                let next = sorted[i + 1]
                if cur.startTick + dur > next.startTick {
                    dur = next.startTick - cur.startTick
                }
            }
            result.append(QuantizedNote(startTick: cur.startTick,
                                        durationTicks: max(dur, gridTicks),
                                        note: cur.note,
                                        velocity: normalizeVelocityIfNeeded(cur.velocity)))
        }
        return result
    }

    private func normalizeVelocityIfNeeded(_ velocity: UInt8) -> UInt8 {
        lane.velocityMode == .normalized ? 100 : velocity
    }
}
