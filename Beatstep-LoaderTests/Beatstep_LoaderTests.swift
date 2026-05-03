import Testing
@testable import Beatstep_Loader

struct BeatstepLoaderTests {
    @Test
    func longestNoteRuleKeepsLongestDurationAtStep() {
        let settings = LaneSettings(
            target: .seq1,
            bspRecordInputChannel: 1,
            intendedOutputChannel: 1,
            patternLengthSteps: 16,
            grid: .sixteenth,
            monoRule: .longestNote,
            velocityMode: .preserve
        )

        let track = MIDITrackData(
            index: 0,
            name: "Lead",
            channels: [0],
            noteMin: 60,
            noteMax: 67,
            noteCount: 2,
            events: [
                noteOn(tick: 0, note: 60, velocity: 96),
                noteOn(tick: 0, note: 67, velocity: 100),
                noteOff(tick: 120, note: 67),
                noteOff(tick: 480, note: 60),
            ]
        )

        let notes = MIDIPreprocessor(lane: settings, ticksPerBeat: 480).process(track)

        #expect(notes.count == 1)
        #expect(notes.first?.note == 60)
    }

    @Test
    func drumLaneKeepsPolyphonicHits() {
        let settings = LaneSettings(
            target: .drum,
            bspRecordInputChannel: 10,
            intendedOutputChannel: 10,
            patternLengthSteps: 16,
            grid: .sixteenth,
            monoRule: .newestNote,
            velocityMode: .preserve
        )

        let track = MIDITrackData(
            index: 1,
            name: "Drums",
            channels: [9],
            noteMin: 36,
            noteMax: 42,
            noteCount: 2,
            events: [
                noteOn(tick: 0, note: 36, velocity: 110),
                noteOn(tick: 0, note: 42, velocity: 90),
                noteOff(tick: 120, note: 36),
                noteOff(tick: 120, note: 42),
            ]
        )

        let notes = MIDIPreprocessor(lane: settings, ticksPerBeat: 480).process(track)

        #expect(notes.count == 2)
        #expect(Set(notes.map(\.note)) == Set([36, 42]))
    }

    private func noteOn(tick: UInt64, note: UInt8, velocity: UInt8) -> RawMIDIEvent {
        RawMIDIEvent(
            absoluteTick: tick,
            isMeta: false,
            metaType: 0,
            metaPayload: Data(),
            statusByte: 0x90,
            data1: note,
            data2: velocity,
            dataLength: 3
        )
    }

    private func noteOff(tick: UInt64, note: UInt8) -> RawMIDIEvent {
        RawMIDIEvent(
            absoluteTick: tick,
            isMeta: false,
            metaType: 0,
            metaPayload: Data(),
            statusByte: 0x80,
            data1: note,
            data2: 0,
            dataLength: 3
        )
    }
}
