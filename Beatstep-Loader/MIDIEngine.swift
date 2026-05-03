//
//  MIDIEngine.swift
//  Beatstep-Loader
//
//  Native Swift MIDI file parser + CoreMIDI sender.
//  No Python, no external dependencies.
//

import Foundation
import CoreMIDI

// MARK: - Raw event (for playback)

struct RawMIDIEvent {
    let absoluteTick: UInt64
    let isMeta: Bool
    let metaType: UInt8
    let metaPayload: Data
    let statusByte: UInt8   // channel events only
    let data1: UInt8
    let data2: UInt8
    let dataLength: Int     // total bytes: 2 or 3
}

// MARK: - Track data (display + playback)

struct MIDITrackData {
    let index: Int
    let name: String
    let channels: Set<UInt8>
    let noteMin: UInt8?
    let noteMax: UInt8?
    let noteCount: Int
    let events: [RawMIDIEvent]
}

// MARK: - Parse errors

enum MIDIParseError: Error, LocalizedError {
    case invalidFile
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .invalidFile:       return "Not a valid MIDI file."
        case .unsupportedFormat: return "Unsupported MIDI format."
        }
    }
}

// MARK: - MIDI file parser

struct MIDIFileParser {

    static func parse(_ url: URL) throws -> (ticksPerBeat: UInt16, tracks: [MIDITrackData]) {
        let data = try Data(contentsOf: url)
        var pos = 0

        // Validate MThd header
        guard data.count >= 14,
              data[pos..<(pos+4)] == Data([0x4D, 0x54, 0x68, 0x64])
        else { throw MIDIParseError.invalidFile }
        pos += 8 // skip tag + length (always 6)

        let format       = readU16(data, pos); pos += 2
        let numTracks    = Int(readU16(data, pos)); pos += 2
        let ticksPerBeat = readU16(data, pos); pos += 2

        guard format <= 2 else { throw MIDIParseError.unsupportedFormat }

        var trackList: [MIDITrackData] = []

        for idx in 0..<numTracks {
            guard pos + 8 <= data.count,
                  data[pos..<(pos+4)] == Data([0x4D, 0x54, 0x72, 0x6B])
            else { break } // MTrk
            pos += 4
            let trackLen = Int(readU32(data, pos)); pos += 4
            let trackEnd = min(pos + trackLen, data.count)
            trackList.append(parseTrack(data, from: pos, to: trackEnd, index: idx))
            pos = trackEnd
        }

        return (ticksPerBeat, trackList)
    }

    // MARK: Track parsing

    private static func parseTrack(_ data: Data, from start: Int, to end: Int, index: Int) -> MIDITrackData {
        var pos            = start
        var absoluteTick   = UInt64(0)
        var runningStatus  = UInt8(0)
        var events         = [RawMIDIEvent]()
        var trackName      = "Track \(index)"
        var channels       = Set<UInt8>()
        var noteMin        = Optional<UInt8>.none
        var noteMax        = Optional<UInt8>.none
        var noteCount      = 0

        while pos < end {
            let (delta, dBytes) = readVLQ(data, pos); pos += dBytes
            absoluteTick += UInt64(delta)
            guard pos < end else { break }

            var status = data[pos]

            // ── Meta event ──────────────────────────────────────────────
            if status == 0xFF {
                pos += 1; guard pos + 1 < end else { break }
                let metaType = data[pos]; pos += 1
                let (mLen, mBytes) = readVLQ(data, pos); pos += mBytes
                let mEnd = min(pos + mLen, end)
                let payload = Data(data[pos..<mEnd]); pos = mEnd
                if metaType == 0x03 {
                    trackName = String(data: payload, encoding: .utf8)?
                        .trimmingCharacters(in: .controlCharacters) ?? trackName
                }
                events.append(RawMIDIEvent(absoluteTick: absoluteTick, isMeta: true,
                                           metaType: metaType, metaPayload: payload,
                                           statusByte: 0, data1: 0, data2: 0, dataLength: 0))
                runningStatus = 0
                continue
            }

            // ── SysEx ────────────────────────────────────────────────────
            if status == 0xF0 || status == 0xF7 {
                pos += 1
                let (sLen, sBytes) = readVLQ(data, pos); pos += sBytes + sLen
                runningStatus = 0
                continue
            }

            // ── Channel event ────────────────────────────────────────────
            if status >= 0x80 {
                runningStatus = status; pos += 1
            } else {
                status = runningStatus // running status — no status byte consumed
            }
            guard status >= 0x80 else { pos += 1; continue }

            let eventType = status & 0xF0
            let channel   = status & 0x0F
            let d1 = pos < end ? data[pos] : 0; pos += 1
            let oneDataByte = eventType == 0xC0 || eventType == 0xD0
            let d2 = oneDataByte ? 0 : (pos < end ? data[pos] : 0)
            if !oneDataByte { pos += 1 }

            // Note tracking
            if eventType == 0x90 && d2 > 0 {
                channels.insert(channel)
                noteCount += 1
                noteMin = noteMin.map { Swift.min($0, d1) } ?? d1
                noteMax = noteMax.map { Swift.max($0, d1) } ?? d1
            } else if eventType == 0x80 || (eventType == 0x90 && d2 == 0) {
                channels.insert(channel)
            }

            events.append(RawMIDIEvent(absoluteTick: absoluteTick, isMeta: false,
                                       metaType: 0, metaPayload: Data(),
                                       statusByte: status, data1: d1, data2: d2,
                                       dataLength: oneDataByte ? 2 : 3))
        }

        return MIDITrackData(index: index, name: trackName, channels: channels,
                             noteMin: noteMin, noteMax: noteMax, noteCount: noteCount,
                             events: events)
    }

    // MARK: Binary helpers

    static func readU16(_ d: Data, _ i: Int) -> UInt16 {
        guard i + 1 < d.count else { return 0 }
        return UInt16(d[i]) << 8 | UInt16(d[i+1])
    }

    static func readU32(_ d: Data, _ i: Int) -> UInt32 {
        guard i + 3 < d.count else { return 0 }
        return UInt32(d[i]) << 24 | UInt32(d[i+1]) << 16 | UInt32(d[i+2]) << 8 | UInt32(d[i+3])
    }

    static func readVLQ(_ d: Data, _ start: Int) -> (value: Int, bytes: Int) {
        var value = 0; var count = 0; var pos = start
        while pos < d.count && count < 4 {
            let byte = d[pos]; pos += 1; count += 1
            value = (value << 7) | Int(byte & 0x7F)
            if byte & 0x80 == 0 { break }
        }
        return (value, count)
    }
}

// MARK: - CoreMIDI engine

final class CoreMIDIEngine {

    struct MIDIDestination: Identifiable, Hashable {
        let id: MIDIEndpointRef
        let name: String
    }

    private var client  = MIDIClientRef()
    private var outPort = MIDIPortRef()

    init() {
        MIDIClientCreate("BeatstepLoader" as CFString, nil, nil, &client)
        MIDIOutputPortCreate(client, "BeatstepOutput" as CFString, &outPort)
    }

    // MARK: Port enumeration

    func refreshDestinations() -> [MIDIDestination] {
        var list = [MIDIDestination]()
        let count = MIDIGetNumberOfDestinations()
        for i in 0..<count {
            let ep = MIDIGetDestination(i)
            var cf: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &cf)
            let name = (cf?.takeRetainedValue() as String?) ?? "MIDI Output \(i)"
            list.append(MIDIDestination(id: ep, name: name))
        }
        return list
    }

    func bspDestination(in destinations: [MIDIDestination]) -> MIDIDestination? {
        destinations.first { $0.name.localizedCaseInsensitiveContains("beatstep") }
    }

    func destination(named name: String, in destinations: [MIDIDestination]) -> MIDIDestination? {
        destinations.first(where: { $0.name == name })
    }

    // MARK: MIDI output test harness

    func sendNoteOn(note: UInt8, velocity: UInt8, channel: UInt8, to dest: MIDIDestination) {
        let zeroBasedChannel = max(channel, 1) - 1
        Self.sendBytes([0x90 | zeroBasedChannel, note, velocity], to: dest.id, outPort: outPort)
    }

    func sendNoteOff(note: UInt8, channel: UInt8, to dest: MIDIDestination) {
        let zeroBasedChannel = max(channel, 1) - 1
        Self.sendBytes([0x80 | zeroBasedChannel, note, 0], to: dest.id, outPort: outPort)
    }

    func sendStart(to dest: MIDIDestination) {
        Self.sendBytes([0xFA], to: dest.id, outPort: outPort)
    }

    func sendStop(to dest: MIDIDestination) {
        Self.sendBytes([0xFC], to: dest.id, outPort: outPort)
    }

    func sendClockTick(to dest: MIDIDestination) {
        Self.sendBytes([0xF8], to: dest.id, outPort: outPort)
    }

    // MARK: Real-time send (call from background task)

    func sendTrack(_ track: MIDITrackData, to dest: MIDIDestination,
                   outputChannel: UInt8, ticksPerBeat: UInt16) async {
        var tempo    = Double(500_000) // µs/beat → 120 BPM
        var lastTick = UInt64(0)

        for event in track.events {
            // Sleep for delta time
            let delta = event.absoluteTick - lastTick
            if delta > 0 {
                let µsPerTick = tempo / Double(ticksPerBeat)
                let nanos     = UInt64(Double(delta) * µsPerTick * 1_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
            lastTick = event.absoluteTick

            // Handle tempo change
            if event.isMeta {
                if event.metaType == 0x51, event.metaPayload.count >= 3 {
                    let p = event.metaPayload
                    tempo = Double((UInt32(p[0]) << 16) | (UInt32(p[1]) << 8) | UInt32(p[2]))
                }
                continue
            }

            let eventType = event.statusByte & 0xF0
            guard eventType >= 0x80, eventType < 0xF0 else { continue }

            // Re-channel to BSP output lane
            let newStatus = eventType | ((max(outputChannel, 1) - 1) & 0x0F)
            let bytes: [UInt8] = event.dataLength == 2
                ? [newStatus, event.data1]
                : [newStatus, event.data1, event.data2]

            Self.sendBytes(bytes, to: dest.id, outPort: outPort)
        }
    }

    // MARK: BSP capture send (quantized, with clock + transport)

    /// Sends preprocessed notes to the BSP with MIDI clock and optional count-in.
    /// Call this AFTER the user has armed Record on the BSP.
    func captureToLane(_ notes: [QuantizedNote],
                       to dest: MIDIDestination,
                       outputChannel: UInt8,
                       gridTicks: UInt64,
                       ticksPerBeat: UInt16,
                       settings: CaptureSettings,
                       sendNoteOffs: Bool = true,
                       stopSignal: () -> Bool) async {
        let nsPerTick = max(settings.nsPerBeat / UInt64(ticksPerBeat), 1)
        let patternNs = UInt64(notes.map(\.startTick).max() ?? 0) * nsPerTick + (gridTicks * nsPerTick)
        let countInNs = settings.countInNs
        let outPort = outPort
        let destinationID = dest.id

        repeat {
            // Transport start
            if settings.sendStartStop { sendStart(to: dest) }

            // Clock + notes run in parallel
            await withTaskGroup(of: Void.self) { group in

                // Clock task — ticks throughout count-in + pattern
                if settings.sendClock {
                    let totalNs = countInNs + patternNs
                    let pulse   = settings.nsPerPulse
                    group.addTask {
                        var elapsed = UInt64(0)
                        while elapsed < totalNs {
                            Self.sendBytes([0xF8], to: destinationID, outPort: outPort)
                            try? await Task.sleep(nanoseconds: pulse)
                            elapsed += pulse
                        }
                    }
                }

                // Count-in: silence for 1 bar, then send notes
                group.addTask {
                    if countInNs > 0 {
                        try? await Task.sleep(nanoseconds: countInNs)
                    }
                    var lastNs = UInt64(0)
                    for note in notes {
                        let noteNs = note.startTick * nsPerTick
                        if noteNs > lastNs {
                            try? await Task.sleep(nanoseconds: noteNs - lastNs)
                        }
                        lastNs = noteNs
                        let zeroBasedChannel = max(outputChannel, 1) - 1
                        Self.sendBytes([0x90 | zeroBasedChannel, note.note, note.velocity], to: destinationID, outPort: outPort)

                        if sendNoteOffs {
                            let offDelay = note.durationTicks * nsPerTick
                            let noteNum = note.note
                            Task {
                                try? await Task.sleep(nanoseconds: offDelay)
                                Self.sendBytes([0x80 | zeroBasedChannel, noteNum, 0], to: destinationID, outPort: outPort)
                            }
                        }
                    }
                    // Wait for rest of pattern
                    if lastNs < patternNs {
                        try? await Task.sleep(nanoseconds: patternNs - lastNs)
                    }
                }
            }

            // Transport stop
            if settings.sendStartStop { sendStop(to: dest) }

        } while settings.loop && !stopSignal()
    }

    // MARK: Packet send

    nonisolated private static func sendBytes(_ bytes: [UInt8], to endpoint: MIDIEndpointRef, outPort: MIDIPortRef) {
        let bufSize = MemoryLayout<MIDIPacketList>.size + bytes.count
        var buffer  = [UInt8](repeating: 0, count: bufSize)
        buffer.withUnsafeMutableBytes { raw in
            let listPtr = raw.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
            let packet  = MIDIPacketListInit(listPtr)
            _ = MIDIPacketListAdd(listPtr, bufSize, packet, 0, bytes.count, bytes)
            MIDISend(outPort, endpoint, listPtr)
        }
    }
}
