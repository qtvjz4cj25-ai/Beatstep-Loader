//
//  BeatstepModel.swift
//  Beatstep-Loader
//
//  Data models + ViewModel. Calls Python backend via subprocess.
//

import Foundation
import Observation

// MARK: - Data Models

struct MIDITrack: Codable, Identifiable, Hashable {
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
}

struct MIDIFileInfo: Codable {
    let type: Int
    let ticksPerBeat: Int
    let tracks: [MIDITrack]
}

// MARK: - ViewModel

@Observable
final class BeatstepModel {
    var fileURL: URL?
    var midiInfo: MIDIFileInfo?
    var seq1Index: Int? = nil
    var seq2Index: Int? = nil
    var drumIndex: Int? = nil
    var availablePorts: [String] = []
    var selectedPort: String = ""
    var logLines: [String] = []
    var isLoading = false
    var isSending = false

    var tracks: [MIDITrack] { midiInfo?.tracks ?? [] }
    var fileName: String { fileURL?.lastPathComponent ?? "No file selected" }

    // MARK: Python bridge

    /// Path to the real python3 binary, resolved once at startup via the user's login shell.
    private var python3Path: String = ""

    /// Runs `zsh -l -c "which python3"` so Homebrew's PATH is loaded exactly as in the terminal.
    private func findPython() async {
        if let path = try? await run("/bin/zsh", args: ["-l", "-c", "which python3"]),
           !path.isEmpty {
            python3Path = path
            log("Python: \(path)")
        } else {
            log("python3 not found — run: brew install python && pip3 install mido python-rtmidi")
        }
    }

    private var scriptsDir: String {
        // Use bundle resources if available (production), else fall back to source dir (dev)
        if let rp = Bundle.main.resourcePath,
           FileManager.default.fileExists(atPath: rp + "/parser.py") {
            return rp + "/"
        }
        return "/Users/i3bus/Documents/Beatstep-Loader/Beatstep-Loader/"
    }

    // MARK: Actions

    func loadFile(_ url: URL) async {
        fileURL = url
        isLoading = true
        log("Loading \(url.lastPathComponent)…")
        do {
            let json = try await run(python3Path, args: [scriptsDir + "parser.py", "--json", url.path])
            let info = try JSONDecoder().decode(MIDIFileInfo.self, from: Data(json.utf8))
            midiInfo = info
            autoAssign(info.tracks)
            log("Loaded \(info.tracks.count) track(s). Auto-assignment applied.")
        } catch {
            log("Error: \(error.localizedDescription)")
        }
        isLoading = false
    }

    func refreshPorts() async {
        await findPython()
        guard !python3Path.isEmpty else { return }
        log("Scanning MIDI ports…")
        do {
            let json = try await run(python3Path, args: [
                "-c", "import mido,json;print(json.dumps(mido.get_output_names()))"
            ])
            let ports = try JSONDecoder().decode([String].self, from: Data(json.utf8))
            availablePorts = ports
            if let bsp = ports.first(where: { $0.localizedCaseInsensitiveContains("beatstep") }) {
                selectedPort = bsp
                log("BeatStep Pro detected: \(bsp)")
            } else if selectedPort.isEmpty, let first = ports.first {
                selectedPort = first
            }
            log("Found \(ports.count) port(s).")
        } catch {
            log("Port scan error: \(error.localizedDescription)")
        }
    }

    func sendTracks() async {
        guard let url = fileURL, !selectedPort.isEmpty else { return }
        isSending = true
        log("Sending to \"\(selectedPort)\"…")
        var args = [url.path, selectedPort]
        if let i = seq1Index { args += ["--seq1", "\(i)"] }
        if let i = seq2Index { args += ["--seq2", "\(i)"] }
        if let i = drumIndex { args += ["--drum", "\(i)"] }
        do {
            let out = try await run(python3Path, args: [scriptsDir + "sender.py"] + args)
            log(out.isEmpty ? "All tracks sent." : out)
        } catch {
            log("Send error: \(error.localizedDescription)")
        }
        isSending = false
    }

    func autoAssign(_ tracks: [MIDITrack]) {
        var pool = tracks
        seq1Index = nil; seq2Index = nil; drumIndex = nil

        // DRUM: ch10 (idx 9) or GM drum note range
        if let t = pool.first(where: { $0.channels.contains(9) }) {
            drumIndex = t.index; pool.removeAll { $0.id == t.id }
        } else if let t = pool.first(where: { ($0.noteMin ?? 0) >= 35 && ($0.noteMax ?? 127) <= 81 }) {
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

    private func avgNote(_ t: MIDITrack) -> Int {
        ((t.noteMin ?? 0) + (t.noteMax ?? 0)) / 2
    }

    func log(_ msg: String) {
        logLines.append(msg)
    }

    private func run(_ executable: String, args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.terminationHandler = { p in
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if p.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
                    continuation.resume(throwing: NSError(
                        domain: "BeatstepLoader", code: Int(p.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: err]
                    ))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}
