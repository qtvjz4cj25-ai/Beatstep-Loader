//
//  ContentView.swift
//  Beatstep-Loader
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Colours & helpers

private extension Color {
    static let bg       = Color(red: 0.10, green: 0.10, blue: 0.18)
    static let bg2      = Color(red: 0.09, green: 0.13, blue: 0.24)
    static let accent   = Color(red: 0.91, green: 0.27, blue: 0.38)
    static let dimText  = Color(white: 0.55)
}

private extension Font {
    static var mono: Font { .system(.body, design: .monospaced) }
    static var monoSm: Font { .system(.footnote, design: .monospaced) }
}

// MARK: - Root view

struct ContentView: View {
    @State private var model = BeatstepModel()
    @State private var showFilePicker = false
    @State private var isDragTarget = false
    @State private var selectedPort = ""

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().overlay(Color.accent)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    fileSection
                    trackTable
                    if !model.tracks.isEmpty {
                        assignmentSection
                    }
                    captureSettingsSection
                    portSection
                    sendSection
                    logSection
                }
                .padding(18)
            }
        }
        .frame(minWidth: 700, minHeight: 620)
        .background(Color.bg)
        .foregroundStyle(Color.white)
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

    // MARK: Header

    private var headerBar: some View {
        HStack {
            Text("BEATSTEP LOADER")
                .font(.system(size: 15, weight: .black, design: .monospaced))
                .foregroundStyle(Color.accent)
            Spacer()
            Text("SEQ1 · SEQ2 · DRUM")
                .font(.monoSm)
                .foregroundStyle(Color.dimText)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.bg2)
    }

    // MARK: File picker

    private var fileSection: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isDragTarget ? Color.accent : Color.white.opacity(0.15),
                        style: StrokeStyle(lineWidth: isDragTarget ? 2 : 1, dash: [6])
                    )
                    .background(Color.bg2.cornerRadius(8))
                VStack(spacing: 4) {
                    Image(systemName: "music.note.list")
                        .font(.title2)
                        .foregroundStyle(isDragTarget ? Color.accent : Color.dimText)
                    Text(model.isLoading ? "Loading…" : model.fileName)
                        .font(.mono)
                        .foregroundStyle(model.fileURL == nil ? Color.dimText : .white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                Task { await model.loadFile(url) }
                return true
            } isTargeted: { isDragTarget = $0 }

            Button("Browse…") { showFilePicker = true }
                .buttonStyle(BSPButtonStyle())
        }
    }

    // MARK: Track table

    private var trackTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Tracks")
            if model.tracks.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "doc.badge.arrow.up")
                            .font(.title2)
                            .foregroundStyle(Color.dimText)
                        Text(model.isLoading ? "Parsing file…" : "Load a .mid file to see tracks")
                            .font(.monoSm)
                            .foregroundStyle(Color.dimText)
                    }
                    .padding(.vertical, 28)
                    Spacer()
                }
                .background(Color.bg2)
                .cornerRadius(8)
            } else {
            Table(model.tracks) {
                TableColumn("#") { t in
                    Text("\(t.index)").font(.mono)
                }
                .width(28)

                TableColumn("Name") { t in
                    Text(t.name).font(.mono)
                }
                .width(min: 100, ideal: 170)

                TableColumn("Ch") { t in
                    Text(t.channelStr).font(.mono)
                }
                .width(50)

                TableColumn("Notes") { t in
                    Text("\(t.noteCount)").font(.mono)
                }
                .width(55)

                TableColumn("Note Range") { t in
                    Text(t.noteRangeStr).font(.mono)
                }
            }
            .frame(height: 175)
            .background(Color.bg2)
            .cornerRadius(8)
            } // end else
        }
    }

    // MARK: Lane assignment

    private var assignmentSection: some View {
        // Only show tracks that have actual note data in the pickers
        let noteTracks = model.tracks.filter { $0.noteCount > 0 }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Lane Assignment")
                Spacer()
                Button("Auto-Assign") { model.autoAssign(model.tracks) }
                    .buttonStyle(BSPButtonStyle(small: true))
            }
            AssignRow(label: "SEQ1 — Lead", tracks: noteTracks, selection: $model.seq1Index)
            AssignRow(label: "SEQ2 — Bass", tracks: noteTracks, selection: $model.seq2Index)
            AssignRow(label: "DRUM",        tracks: noteTracks, selection: $model.drumIndex)
        }
        .padding(12)
        .background(Color.bg2)
        .cornerRadius(8)
    }

    // MARK: Capture settings

    private var captureSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Capture Settings")

            // Row 1: BPM + Pattern Length
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("BPM").font(.monoSm).foregroundStyle(Color.dimText)
                    HStack(spacing: 6) {
                        TextField("", value: $model.capture.bpm, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 62)
                            .font(.mono)
                        Stepper("", value: $model.capture.bpm, in: 40...240, step: 1)
                            .labelsHidden()
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("PATTERN").font(.monoSm).foregroundStyle(Color.dimText)
                    Picker("", selection: $model.capture.patternSteps) {
                        Text("16").tag(16)
                        Text("32").tag(32)
                        Text("64").tag(64)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("GRID").font(.monoSm).foregroundStyle(Color.dimText)
                    Picker("", selection: $model.capture.gridDivision) {
                        Text("1/8").tag(8)
                        Text("1/16").tag(16)
                        Text("1/32").tag(32)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                }

                Spacer()
            }

            // Row 2: Mono mode + toggles
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MONO").font(.monoSm).foregroundStyle(Color.dimText)
                    Picker("", selection: $model.capture.monoMode) {
                        Text("High").tag(CaptureSettings.MonoMode.highest)
                        Text("Low").tag(CaptureSettings.MonoMode.lowest)
                        Text("New").tag(CaptureSettings.MonoMode.newest)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                }

                Spacer()

                Toggle("Clock", isOn: $model.capture.sendClock)
                    .font(.mono)
                    .toggleStyle(.switch)
                Toggle("Count-In", isOn: $model.capture.countIn)
                    .font(.mono)
                    .toggleStyle(.switch)
                Toggle("Loop", isOn: $model.capture.loop)
                    .font(.mono)
                    .toggleStyle(.switch)
            }
        }
        .padding(12)
        .background(Color.bg2)
        .cornerRadius(8)
    }

    // MARK: Port picker

    private var portSection: some View {
        HStack(spacing: 10) {
            sectionLabel("MIDI Port")
            Picker("", selection: $selectedPort) {
                if model.midi.destinations.isEmpty {
                    Text("(no ports found)").tag("")
                }
                ForEach(model.midi.destinations, id: \.name) { d in
                    Text(d.name).tag(d.name)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 300)
            .onAppear {
                if let bsp = model.midi.bspDestination() { selectedPort = bsp.name }
                else if let first = model.midi.destinations.first { selectedPort = first.name }
            }
            Button("Refresh") {
                model.refreshPorts()
                if let bsp = model.midi.bspDestination() { selectedPort = bsp.name }
            }
            .buttonStyle(BSPButtonStyle(small: true))
        }
    }

    // MARK: Send buttons

    private var sendSection: some View {
        let canSend = model.fileURL != nil && !selectedPort.isEmpty && !model.isSending && !model.isLoading
        return VStack(spacing: 10) {
            // Individual lane buttons
            HStack(spacing: 10) {
                LaneSendButton(label: "SEQ1", subtitle: "Lead", color: Color(red: 0.2, green: 0.6, blue: 1.0),
                               enabled: canSend && model.seq1Index != nil) {
                    Task { await model.sendLane("SEQ1", to: selectedPort) }
                }
                LaneSendButton(label: "SEQ2", subtitle: "Bass", color: Color(red: 0.4, green: 0.9, blue: 0.5),
                               enabled: canSend && model.seq2Index != nil) {
                    Task { await model.sendLane("SEQ2", to: selectedPort) }
                }
                LaneSendButton(label: "DRUM", subtitle: "Drums", color: Color(red: 1.0, green: 0.4, blue: 0.6),
                               enabled: canSend && model.drumIndex != nil) {
                    Task { await model.sendLane("DRUM", to: selectedPort) }
                }
            }

            // Send All + Stop row
            HStack(spacing: 10) {
                Button {
                    Task { await model.sendAllParallel(to: selectedPort) }
                } label: {
                    HStack(spacing: 8) {
                        if model.isSending {
                            ProgressView().scaleEffect(0.75).tint(.white)
                            Text("Sending…")
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                            Text("SEND ALL TO BEATSTEP PRO")
                        }
                    }
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(SendButtonStyle())
                .disabled(!canSend)

                if model.isSending {
                    Button {
                        model.stopSending()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                            Text("STOP")
                        }
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .frame(minWidth: 90, minHeight: 42)
                    }
                    .buttonStyle(StopButtonStyle())
                }
            }
        }
    }

    // MARK: Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Log")
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { i, line in
                            Text("› \(line)")
                                .font(.monoSm)
                                .foregroundStyle(Color.dimText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("log_\(i)")
                        }
                    }
                    .padding(8)
                }
                .frame(height: 90)
                .background(Color.bg2)
                .cornerRadius(8)
                .onChange(of: model.logLines.count) { _, _ in
                    if let last = model.logLines.indices.last {
                        withAnimation { proxy.scrollTo("log_\(last)", anchor: .bottom) }
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.accent)
            .tracking(1.5)
    }
}

// MARK: - Assignment row

private struct AssignRow: View {
    let label: String
    let tracks: [MIDITrack]
    @Binding var selection: Int?

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.mono)
                .frame(width: 130, alignment: .leading)
            Picker("", selection: $selection) {
                Text("—").tag(Optional<Int>.none)
                ForEach(tracks) { t in
                    Text("\(t.index): \(t.name)  [\(t.channelStr)]  \(t.noteRangeStr)")
                        .font(.mono)
                        .tag(Optional(t.index))
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Lane send button

private struct LaneSendButton: View {
    let label: String
    let subtitle: String
    let color: Color
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                Text(subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .opacity(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(enabled ? color.opacity(0.2) : Color.white.opacity(0.05))
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

// MARK: - Button styles

private struct BSPButtonStyle: ButtonStyle {
    var small = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(small ? .system(size: 11, weight: .medium) : .system(size: 13, weight: .medium))
            .padding(.horizontal, small ? 10 : 14)
            .padding(.vertical, small ? 5 : 8)
            .background(configuration.isPressed ? Color.accent : Color.white.opacity(0.1))
            .foregroundStyle(.white)
            .cornerRadius(6)
    }
}

private struct SendButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.accent.opacity(0.8) : Color.accent)
            .foregroundStyle(.white)
            .cornerRadius(8)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
    }
}

private struct StopButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(red: 0.7, green: 0.1, blue: 0.1) : Color(red: 0.55, green: 0.1, blue: 0.1))
            .foregroundStyle(.white)
            .cornerRadius(8)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
