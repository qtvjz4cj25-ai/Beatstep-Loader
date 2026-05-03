//
//  ContentView.swift
//  Beatstep-Loader
//

import SwiftUI
import UniformTypeIdentifiers

private extension Color {
    static let bg = Color(red: 0.08, green: 0.09, blue: 0.14)
    static let bg2 = Color(red: 0.11, green: 0.13, blue: 0.20)
    static let panel = Color(red: 0.15, green: 0.17, blue: 0.25)
    static let accent = Color(red: 0.93, green: 0.39, blue: 0.18)
    static let dimText = Color(white: 0.62)
}

private extension Font {
    static var mono: Font { .system(.body, design: .monospaced) }
    static var monoSm: Font { .system(.footnote, design: .monospaced) }
}

struct ContentView: View {
    @State private var model = BeatstepModel()
    @State private var showFilePicker = false
    @State private var isDragTarget = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().overlay(Color.accent.opacity(0.7))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    fileSection
                    trackSection
                    assignmentSection
                    destinationSection
                    inspectorSection
                    if model.selectedInspectorLane == .drum {
                        drumProfileSection
                    }
                    sendSection
                    logSection
                }
                .padding(18)
            }
        }
        .frame(minWidth: 880, minHeight: 760)
        .background(Color.bg)
        .foregroundStyle(.white)
        .onAppear { model.refreshPorts() }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType(filenameExtension: "mid") ?? .data,
                                  UTType(filenameExtension: "midi") ?? .data]
        ) { result in
            if case .success(let url) = result {
                Task { await model.loadFile(url) }
            }
        }
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("MIDI DECOMPOSER")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.accent)
                Text("BeatStep Pro capture assistant: decompose MIDI, match BSP input channel, record clean lanes")
                    .font(.monoSm)
                    .foregroundStyle(Color.dimText)
            }
            Spacer()
            Text("BeatStep Pro Workflow")
                .font(.monoSm)
                .foregroundStyle(Color.dimText)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.bg2)
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Import")
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            isDragTarget ? Color.accent : Color.white.opacity(0.16),
                            style: StrokeStyle(lineWidth: isDragTarget ? 2 : 1, dash: [6])
                        )
                        .background(Color.bg2.cornerRadius(10))
                    VStack(spacing: 6) {
                        Image(systemName: "music.note.list")
                            .font(.title2)
                            .foregroundStyle(isDragTarget ? Color.accent : Color.dimText)
                        Text(model.isLoading ? "Loading..." : model.fileName)
                            .font(.mono)
                            .foregroundStyle(model.fileURL == nil ? Color.dimText : .white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let tempo = model.detectedTempoBPM {
                            Text("Detected tempo: \(tempo) BPM")
                                .font(.monoSm)
                                .foregroundStyle(Color.dimText)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 82)
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    Task { await model.loadFile(url) }
                    return true
                } isTargeted: { isDragTarget = $0 }

                Button("Import MIDI File") {
                    showFilePicker = true
                }
                .buttonStyle(BSPButtonStyle())
            }
        }
    }

    private var trackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Detected Tracks")
            if model.tracks.isEmpty {
                emptyPanel(text: model.isLoading ? "Parsing MIDI..." : "Load a .mid file to inspect tracks")
            } else {
                Table(model.tracks) {
                    TableColumn("#") { track in
                        Text("\(track.index)").font(.mono)
                    }
                    .width(32)

                    TableColumn("Name") { track in
                        Text(track.name).font(.mono)
                    }
                    .width(min: 120, ideal: 220)

                    TableColumn("Ch") { track in
                        Text(track.channelStr).font(.mono)
                    }
                    .width(60)

                    TableColumn("Notes") { track in
                        Text("\(track.noteCount)").font(.mono)
                    }
                    .width(72)

                    TableColumn("Range") { track in
                        Text(track.noteRangeStr).font(.mono)
                    }
                }
                .frame(height: 190)
                .background(Color.bg2)
                .cornerRadius(10)
            }
        }
    }

    private var assignmentSection: some View {
        let noteTracks = model.tracks.filter { $0.noteCount > 0 }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("Lane Assignment")
                Spacer()
                Button("Auto-Assign") {
                    model.autoAssign(model.tracks)
                }
                .buttonStyle(BSPButtonStyle(small: true))
            }

            AssignRow(label: "SEQ 1", tracks: noteTracks, selection: binding(for: .seq1))
            AssignRow(label: "SEQ 2", tracks: noteTracks, selection: binding(for: .seq2))
            AssignRow(label: "DRUM", tracks: noteTracks, selection: binding(for: .drum))
        }
        .padding(12)
        .background(Color.bg2)
        .cornerRadius(10)
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("MIDI Output")
            HStack(spacing: 10) {
                Picker("Destination", selection: $model.selectedDestinationName) {
                    if model.midiDestinations.isEmpty {
                        Text("(no destinations found)").tag("")
                    }
                    ForEach(model.midiDestinations, id: \.name) { destination in
                        Text(destination.name).tag(destination.name)
                    }
                }
                .frame(maxWidth: 380)

                Button("Refresh") {
                    model.refreshPorts()
                }
                .buttonStyle(BSPButtonStyle(small: true))

                Button("Send Test Note") {
                    Task { await model.sendTestNote() }
                }
                .buttonStyle(BSPButtonStyle())
                .disabled(model.selectedDestination == nil || model.isSending)
            }
            Text("Use this first to prove CoreMIDI output is reaching the BeatStep Pro before importing behavior gets blamed.")
                .font(.monoSm)
                .foregroundStyle(Color.dimText)
            Text("For BSP capture: select SEQ 1 or SEQ 2 on hardware, press SHIFT + CHAN, set the same input channel here, set BSP to USB Slave, then press Record on the BSP.")
                .font(.monoSm)
                .foregroundStyle(Color.accent.opacity(0.9))
        }
        .padding(12)
        .background(Color.bg2)
        .cornerRadius(10)
    }

    private var inspectorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("Lane Inspector")
                Spacer()
                Picker("Lane", selection: $model.selectedInspectorLane) {
                    ForEach(TargetLane.allCases) { lane in
                        Text(lane.rawValue).tag(lane)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    infoLine("Assigned Track", value: model.selectedLaneTrackName)
                    infoLine("Generated Notes", value: "\(model.selectedLanePreviewCount)")

                    VStack(alignment: .leading, spacing: 4) {
                        Text("BSP Record Input Channel").font(.monoSm).foregroundStyle(Color.dimText)
                        Stepper(
                            "\(Int(model.selectedLaneSettings.bspRecordInputChannel))",
                            value: selectedLaneRecordChannelBinding,
                            in: 1...16
                        )
                        .font(.mono)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Intended BSP Output Channel").font(.monoSm).foregroundStyle(Color.dimText)
                        Stepper(
                            "\(Int(model.selectedLaneSettings.intendedOutputChannel))",
                            value: selectedLaneOutputChannelBinding,
                            in: 1...16
                        )
                        .font(.mono)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pattern Length").font(.monoSm).foregroundStyle(Color.dimText)
                        Picker("", selection: selectedLanePatternBinding) {
                            Text("16").tag(16)
                            Text("32").tag(32)
                            Text("64").tag(64)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 170)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Grid").font(.monoSm).foregroundStyle(Color.dimText)
                        Picker("", selection: selectedLaneGridBinding) {
                            ForEach(GridResolution.allCases) { grid in
                                Text(grid.rawValue).tag(grid)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mono Rule").font(.monoSm).foregroundStyle(Color.dimText)
                        Picker("", selection: selectedLaneMonoBinding) {
                            ForEach(MonoPriorityRule.allCases) { rule in
                                Text(rule.rawValue).tag(rule)
                            }
                        }
                        .frame(width: 220)
                        .disabled(model.selectedInspectorLane == .drum)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Velocity").font(.monoSm).foregroundStyle(Color.dimText)
                        Picker("", selection: selectedLaneVelocityBinding) {
                            ForEach(VelocityMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .frame(width: 220)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    infoLine("Capture Use", value: "App sends on BSP input channel during Record mode")
                    infoLine("Playback Use", value: "Stored BSP sequence later plays on intended output channel")

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tempo").font(.monoSm).foregroundStyle(Color.dimText)
                        Stepper(
                            "\(Int(model.capture.bpm)) BPM",
                            value: $model.capture.bpm,
                            in: 40...240,
                            step: 1
                        )
                        .font(.mono)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Count-In").font(.monoSm).foregroundStyle(Color.dimText)
                        Picker("", selection: $model.capture.countIn) {
                            ForEach(CountInMode.allCases) { countIn in
                                Text(countIn.rawValue).tag(countIn)
                            }
                        }
                        .frame(width: 180)
                    }

                    Toggle("Send Clock", isOn: $model.capture.sendClock)
                        .font(.mono)
                    Toggle("Send Start/Stop", isOn: $model.capture.sendStartStop)
                        .font(.mono)
                    Toggle("Loop", isOn: $model.capture.loop)
                        .font(.mono)
                    Text("For BSP capture in USB Slave, Send Clock should stay on. Preview is the path for free-running playback without capture.")
                        .font(.monoSm)
                        .foregroundStyle(Color.accent.opacity(0.9))
                }
            }
        }
        .padding(12)
        .background(Color.bg2)
        .cornerRadius(10)
    }

    private var drumProfileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Volca Drum Profile")
            Picker("Mode", selection: $model.volcaDrumProfile.mode) {
                ForEach(VolcaDrumMIDIMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .frame(width: 260)

            if model.volcaDrumProfile.mode == .singleChannel {
                Stepper(
                    "Single-Channel MIDI: \(Int(model.volcaDrumProfile.singleChannel))",
                    value: $model.volcaDrumProfile.singleChannel,
                    in: 1...16
                )
                .font(.mono)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.volcaDrumProfile.partMappings) { mapping in
                        Text("Part \(mapping.partNumber) receives on MIDI Channel \(mapping.outputChannel)")
                            .font(.monoSm)
                            .foregroundStyle(Color.dimText)
                    }
                }
            }

            Text("Do not assume GM drum notes here. Treat this as a user-editable Volca note/part map.")
                .font(.monoSm)
                .foregroundStyle(Color.dimText)
            Text("Volca Drum must use MIDI Clock Source: Auto for external clock/start/stop. CC automation also requires MIDI RX ShortMessage: ON.")
                .font(.monoSm)
                .foregroundStyle(Color.accent.opacity(0.9))
        }
        .padding(12)
        .background(Color.bg2)
        .cornerRadius(10)
    }

    private var sendSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Transport")
            HStack(spacing: 10) {
                LaneSendButton(
                    label: "SEQ 1",
                    subtitle: "Send",
                    color: Color(red: 0.23, green: 0.61, blue: 0.97),
                    enabled: canSend(.seq1)
                ) {
                    Task { await model.sendLane(.seq1) }
                }

                LaneSendButton(
                    label: "SEQ 2",
                    subtitle: "Send",
                    color: Color(red: 0.32, green: 0.86, blue: 0.52),
                    enabled: canSend(.seq2)
                ) {
                    Task { await model.sendLane(.seq2) }
                }

                LaneSendButton(
                    label: "DRUM",
                    subtitle: "Send",
                    color: Color(red: 0.98, green: 0.45, blue: 0.27),
                    enabled: canSend(.drum)
                ) {
                    Task { await model.sendLane(.drum) }
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await model.previewAssignedTracks() }
                } label: {
                    Text(model.isSending ? "Sending..." : "Preview Assigned Tracks (No BSP Capture)")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(SendButtonStyle())
                .disabled(model.selectedDestination == nil || model.isSending)

                Button {
                    model.stopSending()
                } label: {
                    Text("Stop")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .frame(width: 110, height: 42)
                }
                .buttonStyle(StopButtonStyle())
                .disabled(!model.isSending)
            }

            Text("BSP workflow: arm the lane on the BeatStep Pro, enter Record + Play on hardware, then press the lane button here.")
                .font(.monoSm)
                .foregroundStyle(Color.dimText)
            Text("Capture mode sends the lane on the BSP Record Input Channel. Preview uses the Intended BSP Output Channel so the two roles stay separate in the model.")
                .font(.monoSm)
                .foregroundStyle(Color.dimText)
            Text("If you want the BSP to record, use the SEQ 1 / SEQ 2 / DRUM send buttons, not Preview Assigned Tracks.")
                .font(.monoSm)
                .foregroundStyle(Color.accent.opacity(0.9))
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Log")
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { index, line in
                            Text("› \(line)")
                                .font(.monoSm)
                                .foregroundStyle(Color.dimText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 110)
                .background(Color.bg2)
                .cornerRadius(10)
                .onChange(of: model.logLines.count) { _, _ in
                    if let lastIndex = model.logLines.indices.last {
                        withAnimation {
                            proxy.scrollTo(lastIndex, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private var selectedLaneRecordChannelBinding: Binding<UInt8> {
        Binding(
            get: { model.selectedLaneSettings.bspRecordInputChannel },
            set: { model.updateBSPRecordInputChannel(for: model.selectedInspectorLane, channel: $0) }
        )
    }

    private var selectedLaneOutputChannelBinding: Binding<UInt8> {
        Binding(
            get: { model.selectedLaneSettings.intendedOutputChannel },
            set: { model.updateIntendedOutputChannel(for: model.selectedInspectorLane, channel: $0) }
        )
    }

    private var selectedLanePatternBinding: Binding<Int> {
        Binding(
            get: { model.selectedLaneSettings.patternLengthSteps },
            set: { model.updatePatternLength(for: model.selectedInspectorLane, steps: $0) }
        )
    }

    private var selectedLaneGridBinding: Binding<GridResolution> {
        Binding(
            get: { model.selectedLaneSettings.grid },
            set: {
                var settings = model.selectedLaneSettings
                settings.grid = $0
                model.selectedLaneSettings = settings
            }
        )
    }

    private var selectedLaneMonoBinding: Binding<MonoPriorityRule> {
        Binding(
            get: { model.selectedLaneSettings.monoRule },
            set: {
                var settings = model.selectedLaneSettings
                settings.monoRule = $0
                model.selectedLaneSettings = settings
            }
        )
    }

    private var selectedLaneVelocityBinding: Binding<VelocityMode> {
        Binding(
            get: { model.selectedLaneSettings.velocityMode },
            set: {
                var settings = model.selectedLaneSettings
                settings.velocityMode = $0
                model.selectedLaneSettings = settings
            }
        )
    }

    private func binding(for lane: TargetLane) -> Binding<Int?> {
        Binding(
            get: {
                switch lane {
                case .seq1: return model.seq1Index
                case .seq2: return model.seq2Index
                case .drum: return model.drumIndex
                }
            },
            set: {
                switch lane {
                case .seq1: model.seq1Index = $0
                case .seq2: model.seq2Index = $0
                case .drum: model.drumIndex = $0
                }
            }
        )
    }

    private func canSend(_ lane: TargetLane) -> Bool {
        model.selectedDestination != nil && model.track(for: lane) != nil && !model.isSending
    }

    private func infoLine(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.monoSm).foregroundStyle(Color.dimText)
            Text(value).font(.mono)
        }
    }

    private func emptyPanel(text: String) -> some View {
        HStack {
            Spacer()
            Text(text)
                .font(.monoSm)
                .foregroundStyle(Color.dimText)
                .padding(.vertical, 30)
            Spacer()
        }
        .background(Color.bg2)
        .cornerRadius(10)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.accent)
            .tracking(1.4)
    }
}

private struct AssignRow: View {
    let label: String
    let tracks: [MIDITrack]
    @Binding var selection: Int?

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.mono)
                .frame(width: 90, alignment: .leading)
            Picker("", selection: $selection) {
                Text("—").tag(Optional<Int>.none)
                ForEach(tracks) { track in
                    Text("\(track.index): \(track.name) [\(track.channelStr)] \(track.noteRangeStr)")
                        .font(.mono)
                        .tag(Optional(track.index))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct LaneSendButton: View {
    let label: String
    let subtitle: String
    let color: Color
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                Text(subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .opacity(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(enabled ? color.opacity(0.18) : Color.white.opacity(0.05))
            .foregroundStyle(enabled ? color : Color.dimText)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(enabled ? color.opacity(0.6) : Color.white.opacity(0.1), lineWidth: 1)
            )
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct BSPButtonStyle: ButtonStyle {
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(small ? .system(size: 11, weight: .medium) : .system(size: 13, weight: .medium))
            .padding(.horizontal, small ? 10 : 14)
            .padding(.vertical, small ? 6 : 9)
            .background(configuration.isPressed ? Color.accent : Color.panel)
            .foregroundStyle(.white)
            .cornerRadius(7)
    }
}

private struct SendButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.accent.opacity(0.8) : Color.accent)
            .foregroundStyle(.white)
            .cornerRadius(8)
    }
}

private struct StopButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(red: 0.70, green: 0.14, blue: 0.10) : Color(red: 0.55, green: 0.11, blue: 0.10))
            .foregroundStyle(.white)
            .cornerRadius(8)
    }
}

#Preview {
    ContentView()
}
