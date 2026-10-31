//
//  Share.swift
//  Trop
//
//  Created by 686udjie on 2/07/2026.
//

import AVFoundation
import LinkPresentation
import UIKit

/// Presents a `UIActivityViewController` from the key window. Consolidates
/// the copy-pasted window lookup in SongMenuSheet and PlaylistMoreSheet.
/// Pass `afterDismiss` when the sheet must close first (presentation is then
/// deferred slightly so the dismiss animation wins the window).
@MainActor
func presentShareSheet(items: [Any], afterDismiss dismiss: (() -> Void)? = nil) {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
          let window = scene.windows.first(where: { $0.isKeyWindow }),
          let root = window.rootViewController else { return }
    let present = {
        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = window
            popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        var presenter = root
        while let next = presenter.presentedViewController, !next.isBeingDismissed {
            presenter = next
        }
        presenter.present(activityVC, animated: true)
    }
    if let dismiss {
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            present()
        }
    } else {
        present()
    }
}

final class SongShareActivityItemSource: NSObject, UIActivityItemSource {
    private let item: URL
    private let title: String
    private let thumbnail: UIImage?

    init(url: URL, title: String, thumbnail: UIImage?) {
        self.item = url
        self.title = title
        self.thumbnail = thumbnail
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        item
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        item
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        title
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.originalURL = item
        metadata.url = item
        if let thumbnail {
            metadata.imageProvider = NSItemProvider(object: thumbnail)
        }
        return metadata
    }
}

private func extractArtwork(from fileURL: URL) async -> UIImage? {
    let asset = AVURLAsset(url: fileURL)
    guard let metadata = try? await asset.load(.metadata) else { return nil }
    for item in metadata {
        if let data = try? await item.load(.dataValue),
           let image = UIImage(data: data) {
            return image
        }
    }
    return nil
}

private func resolveThumbnail(for song: SongItem, localURL: URL?) async -> UIImage? {
    let highResUrlStr = ArtworkURLs.highRes(song.thumbnailUrl) ?? song.thumbnailUrl
    if let highResUrlStr, let url = URL(string: highResUrlStr),
       let cached = ArtworkLoader.cachedImage(for: url) {
        return cached
    }
    if let thumbStr = song.thumbnailUrl, let url = URL(string: thumbStr),
       let cached = ArtworkLoader.cachedImage(for: url) {
        return cached
    }
    if let localURL, let localImage = await extractArtwork(from: localURL) {
        return localImage
    }
    if let highResUrlStr, let url = URL(string: highResUrlStr),
       let fetched = try? await ArtworkLoader.image(for: url) {
        return fetched
    }
    if let thumbStr = song.thumbnailUrl, let url = URL(string: thumbStr),
       let fetched = try? await ArtworkLoader.image(for: url) {
        return fetched
    }
    return nil
}

@MainActor
func shareSong(
    _ song: SongItem,
    downloadManager: DownloadManager? = nil,
    afterDismiss dismiss: (() -> Void)? = nil
) {
    let downloadManager = downloadManager ?? DownloadManager.shared
    Task { @MainActor in
        let isDownloading: Bool
        if case .downloading = downloadManager.state(for: song.videoId) {
            isDownloading = true
        } else {
            isDownloading = false
        }

        let localURL: URL? = isDownloading ? nil : await downloadManager.localURL(for: song.videoId)
        let thumbnail = await resolveThumbnail(for: song, localURL: localURL)
        let displayTitle = song.artistNamesDisplay.isEmpty ? song.title : "\(song.title) – \(song.artistNamesDisplay)"

        if let localURL {
            let itemSource = SongShareActivityItemSource(
                url: localURL,
                title: displayTitle,
                thumbnail: thumbnail
            )
            presentShareSheet(items: [itemSource], afterDismiss: dismiss)
        } else if let webURL = URL(string: song.webUrl) {
            let itemSource = SongShareActivityItemSource(
                url: webURL,
                title: displayTitle,
                thumbnail: thumbnail
            )
            presentShareSheet(items: [itemSource], afterDismiss: dismiss)
        } else {
            presentShareSheet(items: [song.webUrl], afterDismiss: dismiss)
        }
    }
}

extension URL {
    static func playlistShareURL(id: String) -> URL? {
        URL(string: "https://music.youtube.com/playlist?list=\(id)")
    }
}
