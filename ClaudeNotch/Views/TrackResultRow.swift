import SwiftUI

/// One track in a list — a search result or a queue entry.
///
/// Shared by both so a result and a queued track are visibly the same kind of thing, and
/// so clicking either does the same thing: play it.
struct TrackResultRow: View {
    @Bindable var artwork: ArtworkLoader
    let track: SpotifyTrack
    /// Drawn in the accent colour and bold — used for the track that is playing now.
    var isCurrent: Bool = false
    var onPlay: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            cover
            VStack(alignment: .leading, spacing: 1) {
                Text(track.name)
                    .font(isCurrent ? Theme.caption.weight(.semibold) : Theme.caption)
                    .foregroundStyle(isCurrent ? artwork.accent : Theme.text)
                    .lineLimit(1)
                Text(track.artist)
                    .font(Theme.micro).foregroundStyle(Theme.dim)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(MusicView.clock(track.duration))
                .font(Theme.micro).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Theme.surfaceHi : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onPlay)
    }

    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.surface)
            if let image = artwork.thumbnail(track.artworkURL) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
