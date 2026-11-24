import SwiftUI

/// A book with no note open (SPEC-PARTE2 §2): calm — the name, its sync
/// state and recent notes. The floating explorer is the way in.
public struct BookHomeView<Dot: View>: View {
    public struct Recent: Identifiable, Hashable {
        public let id: String
        public let name: String
        public let folder: String
        public let updated: String
        public init(id: String, name: String, folder: String, updated: String) {
            self.id = id
            self.name = name
            self.folder = folder
            self.updated = updated
        }
    }

    let name: String
    let status: String
    let location: String
    let noteCount: Int
    let recents: [Recent]
    let cursor: Int?
    let loading: Bool
    let dot: Dot
    let onOpen: (Int) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.lumiMotion) private var motion

    public init(name: String, status: String, location: String, noteCount: Int, recents: [Recent], cursor: Int?,
                loading: Bool, @ViewBuilder dot: () -> Dot, onOpen: @escaping (Int) -> Void) {
        self.name = name
        self.status = status
        self.location = location
        self.noteCount = noteCount
        self.recents = recents
        self.cursor = cursor
        self.loading = loading
        self.dot = dot()
        self.onOpen = onOpen
    }

    public var body: some View {
        // Space pass: on a wide window the hero and the recents sit side
        // by side, so the first screen shows ~12 recents instead of 4;
        // narrow windows stack them. The book's light drifts behind.
        GeometryReader { geo in
            let wide = geo.size.width >= 1080
            let pad: CGFloat = geo.size.width < 700 ? 20 : 48
            ZStack(alignment: .topLeading) {
                LivingGradient()
                Group {
                    if wide {
                        HStack(alignment: .top, spacing: 56) {
                            hero.frame(width: 380, alignment: .leading)
                            recentList(max: 14).frame(maxWidth: 720)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 28) {
                            hero
                            recentList(max: 10).frame(maxWidth: 720)
                        }
                    }
                }
                .padding(.horizontal, pad)
                .padding(.top, wide ? 56 : 36)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name) home")
    }

    private var hero: some View {
        let ramp = theme.ramp
        return VStack(alignment: .leading, spacing: 10) {
            Text(name)
                .font(.system(size: LumiType.xxxl, weight: .bold))
                .tracking(LumiType.trackingTight * LumiType.xxxl)
                .foregroundStyle(LinearGradient(colors: [ramp.ink1, ramp.accentInk], startPoint: .leading, endPoint: .trailing))
                .lineLimit(2)
                .lumiEnter(MotionFrom(y: 8, opacity: 0), spring: .soft)
            HStack(spacing: 7) {
                dot
                Text(status)
                Text("·").opacity(0.5)
                Text("\(noteCount) notes")
            }
            .font(ShellFont.chrome)
            .foregroundStyle(ramp.ink3)
            .lumiEnter(MotionFrom(y: 6, opacity: 0), spring: .soft, delay: 0.04)
            Text(location)
                .font(ShellFont.small)
                .foregroundStyle(ramp.ink3)
                .lineLimit(1)
                .truncationMode(.middle)
            VStack(alignment: .leading, spacing: 8) {
                hint("-", "explorer")
                hint("gb", "books")
                hint("space", "palette")
                hint("?", "keys")
            }
            .padding(.top, 18)
            .lumiEnter(MotionFrom(y: 6, opacity: 0), spring: .soft, delay: 0.08)
        }
    }

    private func recentList(max limit: Int) -> some View {
        let ramp = theme.ramp
        return VStack(alignment: .leading, spacing: 2) {
            Text("RECENT")
                .font(ShellFont.small)
                .tracking(LumiType.trackingCaps * 10.5)
                .foregroundStyle(ramp.ink3)
                .padding(.bottom, 6)
            if recents.isEmpty {
                if loading {
                    ForEach(0..<3, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 4).fill(ramp.surface2)
                            .frame(width: [300, 240, 270][i], height: 12).padding(.vertical, 9)
                    }
                } else {
                    Text("nothing opened here yet")
                        .font(ShellFont.chrome)
                        .foregroundStyle(ramp.ink3)
                }
            }
            ForEach(Array(recents.prefix(limit).enumerated()), id: \.element.id) { i, r in
                Button { onOpen(i) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 11))
                            .foregroundStyle(i == cursor ? theme.primary : ramp.ink3)
                        Text(r.name)
                            .font(ShellFont.row)
                            .foregroundStyle(ramp.ink1)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        Text(r.folder)
                            .font(ShellFont.small)
                            .foregroundStyle(ramp.ink3)
                            .lineLimit(1)
                        Text(r.updated)
                            .font(ShellFont.small)
                            .foregroundStyle(ramp.ink3)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(i == cursor ? theme.selectionRow : ramp.surface1.opacity(0.0001)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(LiftButtonStyle(enabled: motion))
                .staggerIn(i, active: motion)
            }
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            KeyCap(key)
            Text(label).font(ShellFont.small).foregroundStyle(theme.textDim)
        }
    }
}
