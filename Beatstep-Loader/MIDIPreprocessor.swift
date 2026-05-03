//
//  MIDIPreprocessor.swift
//  Beatstep-Loader
//
//  Converts raw MIDI track data into BSP-ready monophonic step sequences.
//  Pipeline: extract note pairs → quantize → clip to pattern → mono reduce → resolve overlaps
//

import Foundation

// MARK: - Settings

struct CaptureSettings {
    var bpm: Double      = 120
    var patternSteps: Int = 16    // 16, 32, 64
    var gridDivision: Int = 16    // 8, 16, or 32  (1/8, 1/16, 1/32)
    var monoMode: MonoMode = .highest
    var countIn: Bool    = true   // 1-bar count-in before notes start
    var loop: Bool       = false  // repeat pattern until stopped
    var sendClock: Bool  = true   // send MIDI clock (24 PPQN)

    enum MonoMode: String, CaseIterable, Identifiable {
        case highest = "Highest"
        case lowest  = "Lowest"
        case newest  = "Newest"
        var id: String { rawValue }
    }

    /// Ticks per grid step at a given file resolution
    func gridTicks(ticksPerBeat: UInt16) -> UInt64 {
        // 1 beat = ticksPerBeat ticks; 1/gridDivision note = ticksPerBeat * 4 / gridDivision
        UInt64(ticksPerBeat) * 4 / UInt64(gridDivision)
    }

    /// Total ticks in the pattern
    func patternTicks(ticksPerBeat: UInt16) -> UInt64 {
        gridTicks(ticksPerBeat: ticksPerBeat) * UInt64(patternSteps)
    }

    /// Nanoseconds per beat
    var nsPerBeat: UInt64 { UInt64(60_000_000_000.0 / bpm) }

    /// Nanoseconds per MIDI clock pulse (24 PPQN)
    var nsPerPulse: UInt64 { nsPerBeat / 24 }
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

    let settings: CaptureSettings
    let ticksPerBeat: UInt16

    private var gridTicks:    UInt64 { settings.gridTicks(ticksPerBeat: ticksPerBeat) }
    private var patternTicks: UInt64 { settings.patternTicks(ticksPerBeat: ticksPerBeat) }

    // MARK: Main pipeline

    func process(_ trackData: MIDITrackData) -> [QuantizedNote] {
        let pairs    = extractNotePairs(trackData)
        let quantized = pairs.map { quantize($0) }
        let clipped  = clip(quantized)
        let mono     = reduceMono(clipped)
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
            switch settings.monoMode {
            case .highest: return group.max(by: { $0.note < $1.note })!
            case .lowest:  return group.min(by: { $0.note < $1.note })!
            case .newest:  return group.last!
            }
        }
    }

    // MARK: Step 5 — resolve overlaps (truncate preceding note)

    private func resolveOverlaps(_ notes: [RawNote]) -> [QuantizedNote] {
        var result = [QuantizedNote]()
        var sorted = notes.sorted { $0.startTick < $1.startTick }

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
                                        note: cur.note, velocity: cur.velocity))
        }
        return result
    }
}
