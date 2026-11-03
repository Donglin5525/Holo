import Foundation
import CoreText

/// 进程内注册真实随包字库；不安装系统字体、不读取用户数据。
@main
struct ThoughtFontResourceStandaloneTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let names = ["HoloNoteSerif-Regular", "HoloNoteSerif-Bold", "HoloNoteHand-Regular", "HoloNoteHand-Bold"]
        let plistData = try Data(contentsOf: root.appendingPathComponent("Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        let provided = plist?["UIAppFonts"] as? [String] ?? []
        precondition(Set(provided) == Set(names.map { "\($0).ttf" }), "Info 字体注册项必须与实际资源一致")
        let directory = root.appendingPathComponent("Holo/Resources/ThoughtFonts")
        for name in names {
            let url = directory.appendingPathComponent(name + ".ttf")
            var error: Unmanaged<CFError>?
            precondition(CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error), "实际字库必须可注册")
            let font = CTFontCreateWithName(name as CFString, 17, nil)
            precondition(CTFontCopyPostScriptName(font) as String == name, "字体名不匹配不能静默以系统字冒充")
            let characters = Array("想法编辑记录模板分享字體閱讀測試ABC123".utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            precondition(CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count), "常用简繁体、拉丁字与数字必须覆盖")
            let isBold = CTFontGetSymbolicTraits(font).contains(.boldTrait)
            precondition(isBold == name.hasSuffix("Bold"), "加粗字重必须保留")
        }
        for filename in ["hand-OFL.txt", "serif-OFL.txt"] {
            let license = try String(contentsOf: directory.appendingPathComponent(filename), encoding: .utf8)
            precondition(license.contains("SIL OPEN FONT LICENSE"), "随包许可不可缺失")
        }
        print("PASS: 四个真实字体可注册、名称/简繁字形/数字/加粗与随包许可一致")
    }
}
