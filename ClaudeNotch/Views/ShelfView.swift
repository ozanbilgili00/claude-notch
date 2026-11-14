import SwiftUI
import UniformTypeIdentifiers

/// The Shelf tab: files parked on the notch, ready to be dragged back out.
///
/// A list rather than a grid of icons. File names here are long and the panel's type is
/// monospaced, so a grid would truncate nearly every label to something unrecognisable —
/// the whole point of the shelf is knowing at a glance what you put on it.
struct ShelfView: View {
    @Bindable var shelf: ShelfStore
    /// Panel is held open while a row is being dragged out, the same lock quick settings
    /// uses — otherwise the pointer leaving the panel collapses it mid-drag.
    var onDragOut: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if shelf.items.isEmpty {
                emptyState
            } else {
                header
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Bookmarks are re-checked here and nowhere else: whether a file still exists only
        // matters at the moment someone looks at the shelf.
        .onAppear { shelf.refresh() }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text(Lcount(.shelfCountOne, .shelfCountMany, shelf.items.count))
                .font(Theme.micro).foregroundStyle(Theme.dim)
            Spacer()
            Button {
                withAnimation(Theme.Motion.quick) { shelf.clear() }
            } label: {
                Text(L(.shelfClear))
                    .font(Theme.micro).foregroundStyle(Theme.dim)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(shelf.items) { item in
                    ShelfRow(shelf: shelf, item: item, onDragOut: onDragOut)
                        .transition(.blurReplace)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 26))
                .foregroundStyle(Theme.dim)
            Text(L(.shelfEmptyTitle))
                .font(Theme.title).foregroundStyle(Theme.textDim)
            Text(L(.shelfEmptyHint))
                .font(Theme.caption).foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                .strokeBorder(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .padding(12)
                .allowsHitTesting(false)
        )
    }
}

/// One file on the shelf.
private struct ShelfRow: View {
    @Bindable var shelf: ShelfStore
    let item: ShelfItem
    var onDragOut: (Bool) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Everything except the remove button is the drag handle. The button stays a
            // real SwiftUI control by sitting *beside* the handle rather than on top of
            // it: the handle is an AppKit view, and AppKit hit-testing would claim any
            // click over its frame before SwiftUI ever saw it.
            content
                .frame(maxWidth: .infinity)
                .overlay(dragHandle)

            Button { withAnimation(Theme.Motion.quick) { shelf.remove(item) } } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
            }
            .buttonStyle(.plain)
            // Kept in the layout at zero opacity rather than inserted on hover: appearing
            // controls shift the row, and the pointer that caused it ends up over
            // something that moved out from under it.
            .opacity(hovering ? 1 : 0)
            .help(L(.shelfRemove))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                .fill(hovering ? Theme.surfaceHi : Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                )
        )
    }

    private var content: some View {
        HStack(spacing: 10) {
            Image(nsImage: shelf.icon(for: item))
                .resizable()
                .frame(width: 28, height: 28)
                .opacity(item.isMissing ? 0.4 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(Theme.body)
                    .foregroundStyle(item.isMissing ? Theme.dim : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                subtitle
            }

            Spacer(minLength: 6)

            if !item.fileExtension.isEmpty {
                Badge(text: item.fileExtension, tint: Theme.textDim)
            }
        }
        .contentShape(Rectangle())
    }

    /// A missing file has nothing to hand over and nothing to open, so it gets no handle
    /// at all — the row simply stops responding rather than failing when clicked.
    @ViewBuilder
    private var dragHandle: some View {
        if !item.isMissing {
            FileDragHandle(
                url: item.url,
                icon: shelf.icon(for: item),
                onOpen: { shelf.open(item) },
                onReveal: { shelf.revealInFinder(item) },
                onRemove: { withAnimation(Theme.Motion.quick) { shelf.remove(item) } },
                onDragSession: onDragOut,
                onHover: { hovering = $0 }
            )
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if item.isMissing {
            Text(L(.shelfMissing))
                .font(Theme.micro).foregroundStyle(Theme.red.opacity(0.8))
        } else if let size = shelf.size(of: item) {
            Text(Self.formatter.string(fromByteCount: size))
                .font(Theme.micro).foregroundStyle(Theme.dim)
        }
    }

    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
}
