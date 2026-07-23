import SwiftUI

/// Full log viewer: last 100 lines, search, copy, syntax tint, auto-scroll to bottom.
struct LogViewer: View {
    let lines: [String]
    @State private var query = ""

    private var filtered: [(Int, String)] {
        Array(lines.enumerated()).filter {
            query.isEmpty || $0.1.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.dim)
                TextField("Search log", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.text)
                Spacer()
                Button {
                    SessionActions.copy(lines.joined(separator: "\n"))
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundStyle(Theme.dim)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filtered, id: \.0) { idx, line in
                            Text(line)
                                .font(Theme.micro)
                                .foregroundStyle(color(for: line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 140)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.4)))
                .onChange(of: lines.count) { _, _ in
                    if let last = filtered.last?.0 {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
                .onAppear {
                    if let last = filtered.last?.0 { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private func color(for line: String) -> Color {
        let l = line.lowercased()
        if l.contains("error") || l.contains("fail") { return Theme.red }
        if l.contains("pass") || l.contains("success") || l.contains("✓") { return Theme.green }
        if line.hasPrefix("$") || line.hasPrefix("→") { return Theme.blue }
        return Theme.textDim
    }
}
