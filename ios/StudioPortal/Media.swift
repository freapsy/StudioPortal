import SwiftUI
import AVKit
import Photos
import QuickLook

/// Image from the Mac mini's library (thumbnail or full file), loaded with the token.
struct RemoteImage: View {
    @EnvironmentObject private var downloads: Downloads
    let path: String
    var size = 400
    var full = false
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if failed { Image(systemName: "photo").font(.title).foregroundStyle(.secondary) }
            else { ProgressView() }
        }
        .task(id: path) {
            if let url = downloads.local(path), let localImage = UIImage(contentsOfFile: url.path) {
                image = localImage
                return
            }
            let r = full ? API.request("/api/file", ["path": path]) : API.request("/api/thumb", ["path": path, "size": "\(size)"])
            if let data = try? await API.data(r), let ui = UIImage(data: data) { image = ui } else { failed = true }
        }
    }
}

struct FileActions: View {
    @EnvironmentObject private var downloads: Downloads
    let item: LibraryItem
    @State private var note: String?
    @State private var remove = false

    private var ext: String { (item.file as NSString).pathExtension.lowercased() }
    private var photoKind: Bool { ["png", "jpg", "jpeg", "heic", "mp4", "mov"].contains(ext) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let local = downloads.local(item.file) {
                HStack {
                    ShareLink(item: local) { Label("Teilen", systemImage: "square.and.arrow.up") }
                    if photoKind { Button("In Fotos", systemImage: "photo.badge.plus") { save(local) } }
                }.buttonStyle(.bordered)
            }
            if downloads.fetching.contains(item.file) {
                ProgressView("Wird geladen …")
            } else if let entry = downloads.entries[item.file], entry.saved {
                Button("Offline-Datei entfernen", systemImage: "arrow.down.circle", role: .destructive) { remove = true }
            } else {
                Button("Offline behalten", systemImage: "arrow.down.circle") {
                    Task {
                        do { _ = try await downloads.fetch(item, keep: true); note = "Offline gespeichert." }
                        catch { note = error.localizedDescription }
                    }
                }.buttonStyle(.bordered)
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .confirmationDialog("Offline-Datei vom iPhone entfernen?", isPresented: $remove, titleVisibility: .visible) {
            Button("Entfernen", role: .destructive) {
                do { try downloads.remove(item.file, cacheOnly: false); note = nil }
                catch { note = error.localizedDescription }
            }
        }
    }

    private func save(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { Task { @MainActor in note = "Kein Zugriff auf Fotos." }; return }
            PHPhotoLibrary.shared().performChanges({
                if item.kind == "video" { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }
                else { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url) }
            }) { ok, _ in Task { @MainActor in note = ok ? "In Fotos gesichert." : "Sichern fehlgeschlagen." } }
        }
    }
}

struct FileDetail: View {
    @EnvironmentObject private var downloads: Downloads
    let path: String
    var title: String = ""
    var preview: String? = nil
    var item: LibraryItem? = nil
    @State private var failure: String?
    @State private var player: AVPlayer?
    @State private var previewURL: URL?

    private var media: LibraryItem { item ?? .placeholder(path) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let local = downloads.local(path) {
                    switch media.kind {
                    case "image":
                        if let image = UIImage(contentsOfFile: local.path) {
                            Image(uiImage: image).resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        } else { Button("Datei ansehen", systemImage: "eye") { previewURL = local } }
                    case "video":
                        VideoPlayer(player: player).aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    case "music":
                        if let preview { RemoteImage(path: preview, size: 800).clipShape(RoundedRectangle(cornerRadius: 16)) }
                        VideoPlayer(player: player).frame(height: 64)
                    default:
                        Button("Datei ansehen", systemImage: "eye") { previewURL = local }.buttonStyle(.bordered)
                    }
                } else if let failure {
                    Label(failure, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                } else if media.kind != "model" {
                    ProgressView("Wird geladen …").frame(maxWidth: .infinity, minHeight: 140)
                }
                if media.kind == "model", let preview {
                    RemoteImage(path: preview, size: 1000).clipShape(RoundedRectangle(cornerRadius: 16))
                }
                if !title.isEmpty { Text(title).font(.headline).textSelection(.enabled) }
                FileActions(item: media)
            }.padding()
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($previewURL)
        .task {
            guard media.kind != "model" || downloads.local(path) != nil else { return }
            do {
                let local = try await downloads.fetch(media)
                guard !Task.isCancelled else {
                    if downloads.discardAfterViewing { try? downloads.remove(path, cacheOnly: true) }
                    return
                }
                if media.kind == "music" || media.kind == "video", player == nil { player = AVPlayer(url: local) }
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
        .onChange(of: downloads.local(path)) { _, url in
            if let url, media.kind == "music" || media.kind == "video" {
                if player == nil { player = AVPlayer(url: url) }
            } else if url == nil {
                player?.pause()
                player = nil
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
            if downloads.discardAfterViewing { try? downloads.remove(path, cacheOnly: true) }
        }
    }
}
