import SwiftUI

struct TransferProgressView: View {
    let state: TransferViewModel.TransferState
    let progress: Double
    let speedMBps: Double

    var body: some View {
        VStack(spacing: 8) {
            switch state {
            case .idle:
                EmptyView()

            case .waitingForClient:
                Label("Waiting for Mac to connect…", systemImage: "clock")
                    .foregroundStyle(.secondary)

            case .transferring(let filename):
                VStack(spacing: 6) {
                    ProgressView(value: progress)
                    HStack {
                        Text(filename)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(String(format: "%.1f MB/s", speedMBps))
                            .font(.caption.monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                }

            case .done(let stats):
                VStack(spacing: 4) {
                    Label(
                        "\(stats.sentCount) file(s) sent" + (stats.failedCount > 0 ? ", \(stats.failedCount) failed" : ""),
                        systemImage: "checkmark.circle"
                    )
                    .foregroundStyle(stats.failedCount > 0 ? .orange : .green)

                    Text("\(sizeString(stats.totalBytes))  •  \(durationString(stats.duration))  •  avg \(String(format: "%.1f", stats.averageSpeedMBps)) MB/s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

            case .error(let msg):
                Label(msg, systemImage: "xmark.circle")
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
    }

    private func sizeString(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        let mb = Double(bytes) / 1_000_000
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1000)
    }

    private func durationString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}
