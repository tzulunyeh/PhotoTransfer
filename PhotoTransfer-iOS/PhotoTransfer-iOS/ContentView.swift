import SwiftUI
import PhotosUI

struct ContentView: View {
    @State private var server = TransferServer()
    @State private var vm: TransferViewModel
    @State private var showPicker = false

    init() {
        let s = TransferServer()
        _server = State(initialValue: s)
        _vm = State(initialValue: TransferViewModel(server: s))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Connection status bar
            HStack(spacing: 8) {
                Circle()
                    .fill(server.hasClient ? .green : (server.isListening ? .orange : .red))
                    .frame(width: 8, height: 8)
                Text(server.hasClient
                     ? "Mac connected"
                     : (server.isListening ? "Listening on port \(TransferConstants.port)…" : "Starting…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            // Selected photos list
            if vm.assets.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No photos selected")
                        .foregroundStyle(.secondary)
                    Button("Select Photos…") { showPicker = true }
                        .buttonStyle(.bordered)
                }
                Spacer()
            } else {
                List {
                    ForEach(vm.assets) { asset in
                        HStack {
                            Image(systemName: asset.filename == "Video" || asset.filename.hasSuffix("MOV") || asset.filename.hasSuffix("MP4") ? "video" : "photo")
                                .foregroundStyle(.secondary)
                            Text(asset.filename)
                                .lineLimit(1)
                            Spacer()
                            if asset.fileSize > 0 {
                                Text(fileSizeString(asset.fileSize))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }

            Divider()

            // Bottom toolbar
            VStack(spacing: 10) {
                TransferProgressView(state: vm.transferState, progress: vm.progress, speedMBps: vm.speedMBps)

                HStack(spacing: 12) {
                    if isTransferring {
                        Button {
                            vm.cancelTransfer()
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else {
                        Button("Select Photos") { showPicker = true }
                            .buttonStyle(.bordered)

                        Button {
                            vm.startTransfer()
                        } label: {
                            Label("Send \(vm.selectedAssets.count)", systemImage: "arrow.up.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.selectedAssets.isEmpty)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 12)
        }
        .sheet(isPresented: $showPicker) {
            PhotoPickerView { results in
                vm.setSelectedAssets(from: results)
            }
            .ignoresSafeArea()
        }
        .onAppear { server.start() }
        .onDisappear { server.stop() }
    }

    private var isTransferring: Bool {
        if case .transferring = vm.transferState { return true }
        return false
    }

    private func fileSizeString(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        return mb >= 1 ? String(format: "%.1f MB", mb) : String(format: "%.0f KB", Double(bytes) / 1000)
    }
}

#Preview {
    ContentView()
}
