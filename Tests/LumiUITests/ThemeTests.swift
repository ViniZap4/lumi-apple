import Testing
@testable import LumiUI

@Suite("LumiTheme catalog")
struct LumiThemeTests {
    @Test("twelve themes are registered")
    func twelveThemes() {
        #expect(LumiTheme.allCases.count == 12)
    }

    @Test("each theme has six logo colors")
    func sixLogoColors() {
        for theme in LumiTheme.allCases {
            #expect(theme.tokens.logoColors.count == 6, "theme \(theme.rawValue) has wrong logo color count")
        }
    }

    @Test("dark and light partitions cover all themes")
    func partitionsCover() {
        let dark = Set(LumiTheme.darkThemes.map(\.rawValue))
        let light = Set(LumiTheme.lightThemes.map(\.rawValue))
        let all = Set(LumiTheme.allCases.map(\.rawValue))
        #expect(dark.isDisjoint(with: light))
        #expect(dark.union(light) == all)
    }

    @Test("token name matches enum raw value")
    func nameAndRawAlign() {
        for theme in LumiTheme.allCases {
            #expect(theme.tokens.name == theme.rawValue)
        }
    }
}
