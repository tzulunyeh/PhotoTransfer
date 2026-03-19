import SwiftUI
import Network

@Observable
@MainActor
final class ConnectionState {
    enum Status {
        case searching
        case connected
        case receiving(filename: String)
        case error(String)
    }

    var status: Status = .searching
    var receivedFiles: [String] = []
    var progress: Double = 0
    var speedMBps: Double = 0
    var outputDirectory: URL = {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        return desktop.appendingPathComponent("PhotoTransfer")
    }()

    private var receiver: FileReceiver?
    private var speedSampleBytes: Int64 = 0
    private var speedSampleTime: Date = Date()

    func start() {
        Task { await connectLoop() }
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose folder to save transferred photos"
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
        }
    }

    // MARK: - Private

    private func connectLoop() async {
        while true {
            do {
                status = .searching
                let conn = try await USBMuxClient.connectToDevice(port: TransferConstants.port)
                status = .connected
                print("[ConnectionState] Tunnel established")
                await receive(on: conn)
                // When receive ends (disconnected), loop back and search again
            } catch {
                print("[ConnectionState] Connect failed: \(error)")
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func receive(on conn: NWConnection) async {
        createDirectoryIfNeeded(outputDirectory)

        speedSampleBytes = 0
        speedSampleTime = Date()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let recv = FileReceiver(outputDirectory: outputDirectory)
            var resumed = false
            var lastReceivedBytes: UInt64 = 0

            recv.onProgress = { [weak self] received, total in
                let delta = Int(received - lastReceivedBytes)
                lastReceivedBytes = received
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.progress = total > 0 ? Double(received) / Double(total) : 0
                    self.updateSpeed(bytes: delta)
                }
            }
            recv.onFileCompleted = { [weak self] filename in
                lastReceivedBytes = 0
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !self.receivedFiles.contains(filename) {
                        self.receivedFiles.append(filename)
                    }
                    self.status = .connected
                    self.progress = 0
                    self.speedMBps = 0
                }
            }
            recv.onFileStarted = { [weak self] filename in
                DispatchQueue.main.async {
                    self?.status = .receiving(filename: filename)
                }
            }
            recv.onError = { [weak self] _ in
                DispatchQueue.main.async {
                    self?.progress = 0
                    self?.speedMBps = 0
                }
                if !resumed { resumed = true; cont.resume() }
            }
            recv.onDisconnected = {
                if !resumed { resumed = true; cont.resume() }
            }

            self.receiver = recv
            recv.start(on: conn)
        }
    }

    private func updateSpeed(bytes: Int) {
        speedSampleBytes += Int64(bytes)
        let now = Date()
        let elapsed = now.timeIntervalSince(speedSampleTime)
        if elapsed >= 0.5 {
            speedMBps = Double(speedSampleBytes) / elapsed / 1_000_000
            speedSampleBytes = 0
            speedSampleTime = now
        }
    }

    private func createDirectoryIfNeeded(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

struct ContentView: View {
    @State private var state = ConnectionState()

    var body: some View {
        VStack(spacing: 20) {
            // Status icon + text
            VStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .imageScale(.large)
                    .foregroundStyle(statusColor)
                Text(statusText)
                    .foregroundStyle(statusColor)
            }

            // Progress (shown while receiving)
            if case .receiving(let filename) = state.status {
                VStack(spacing: 6) {
                    ProgressView(value: state.progress)
                    HStack {
                        Text(filename)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(String(format: "%.1f MB/s", state.speedMBps))
                            .font(.caption.monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Output folder
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(state.outputDirectory.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Change…") { state.chooseOutputDirectory() }
                    .font(.caption)
            }

            // Received file list
            if !state.receivedFiles.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(state.receivedFiles, id: \.self) { name in
                            Label(name, systemImage: "photo")
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
        .onAppear { state.start() }
    }

    private var statusIcon: String {
        switch state.status {
        case .searching:       return "iphone.slash"
        case .connected:       return "iphone.and.arrow.forward"
        case .receiving:       return "arrow.down.circle"
        case .error:           return "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch state.status {
        case .searching:       return .secondary
        case .connected:       return .green
        case .receiving:       return .blue
        case .error:           return .red
        }
    }

    private var statusText: String {
        switch state.status {
        case .searching:               return "Searching for iPhone…"
        case .connected:               return "Connected — ready to receive"
        case .receiving(let filename): return "Receiving \(filename)"
        case .error(let msg):          return msg
        }
    }
}

#Preview {
    ContentView()
}
