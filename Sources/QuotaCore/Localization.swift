import Foundation

/// The only list of interface languages. Settings options, system-language
/// matching and the fallback are all derived from it.
///
/// To add a language, add `Resources/<code>.lproj/Localizable.strings` with
/// every key and register it here. The first entry is the fallback; it must
/// match `defaultLocalization` in Package.swift.
public struct AppLanguage:Equatable,Identifiable {
    /// The `.lproj` name and BCP 47 tag, for example "en" or "zh-Hans".
    public let code:String
    /// Shown in the language picker in its own language.
    public let displayName:String
    /// Additional system tags that select this language before the generic
    /// primary-subtag match, for example region tags of a script variant.
    public let systemAliases:[String]
    public var id:String { code }
    init(code:String,displayName:String,systemAliases:[String]=[]) {
        self.code=code;self.displayName=displayName;self.systemAliases=systemAliases
    }
    public static let supported:[AppLanguage]=[
        AppLanguage(code:"en",displayName:"English"),
        AppLanguage(code:"zh-Hans",displayName:"简体中文"),
    ]
    public static var fallback:AppLanguage { supported[0] }
    public static func registered(_ code:String?)->AppLanguage? {
        guard let code else { return nil }
        return supported.first { $0.code.caseInsensitiveCompare(code) == .orderedSame }
    }
    /// Walks the user's ordered system languages; uses the fallback when none
    /// of them is supported.
    public static func matching(preferredLanguages:[String])->AppLanguage {
        for preferred in preferredLanguages {
            let tag=preferred.replacingOccurrences(of:"_",with:"-").lowercased()
            if let exact=supported.first(where:{ language in
                ([language.code]+language.systemAliases).contains { alias in
                    let alias=alias.lowercased()
                    return tag == alias || tag.hasPrefix(alias+"-")
                }
            }) { return exact }
            let primary=Self.primarySubtag(tag)
            if let related=supported.first(where:{ Self.primarySubtag($0.code.lowercased()) == primary }) { return related }
        }
        return fallback
    }
    private static func primarySubtag(_ tag:String)->String {
        tag.split(separator:"-").first.map(String.init) ?? tag
    }
}

/// Localized interface text. Values use `%@` or `%1$@` placeholders and `%%`
/// for a literal percent sign.
public enum L10n {
    public private(set) static var language=AppLanguage.matching(preferredLanguages:Locale.preferredLanguages)
    /// `nil` or an unregistered code follows the system languages.
    @discardableResult
    public static func apply(languageCode:String?,preferredLanguages:[String]=Locale.preferredLanguages)->Bool {
        let next=AppLanguage.registered(languageCode) ?? AppLanguage.matching(preferredLanguages:preferredLanguages)
        guard next != language else { return false }
        language=next
        return true
    }
    public static func string(_ key:String)->String {
        substitute(raw(key),[])
    }
    public static func format(_ key:String,_ arguments:CustomStringConvertible...)->String {
        substitute(raw(key),arguments.map(\.description))
    }
    static func raw(_ key:String,language:AppLanguage=L10n.language)->String {
        tables[language.code]?[key] ?? tables[AppLanguage.fallback.code]?[key] ?? key
    }
    static let tables:[String:[String:String]]={
        var result:[String:[String:String]]=[:]
        for language in AppLanguage.supported { result[language.code]=table(for:language.code) }
        return result
    }()
    static func table(for code:String)->[String:String]? {
        guard let url=resourceDirectory.flatMap({ tableURL(in:$0,code:code) }),
              let data=try? Data(contentsOf:url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from:data,options:[],format:nil)) as? [String:String]
    }
    /// The packaged app carries the tables in Contents/Resources; SwiftPM
    /// builds and tests use the module resource bundle.
    private static let resourceDirectory:URL?={
        if let main=Bundle.main.resourceURL,tableURL(in:main,code:AppLanguage.fallback.code) != nil { return main }
        return Bundle.module.resourceURL ?? Bundle.module.bundleURL
    }()
    /// SwiftPM may lowercase `.lproj` names (zh-hans.lproj), so match them
    /// case-insensitively instead of through `Bundle` localization lookup.
    private static func tableURL(in directory:URL,code:String)->URL? {
        let names=(try? FileManager.default.contentsOfDirectory(atPath:directory.path)) ?? []
        guard let name=names.first(where:{ $0.caseInsensitiveCompare(code+".lproj") == .orderedSame }) else { return nil }
        let url=directory.appendingPathComponent(name).appendingPathComponent("Localizable.strings")
        return FileManager.default.fileExists(atPath:url.path) ? url:nil
    }
    static func substitute(_ template:String,_ arguments:[String])->String {
        guard template.contains("%") else { return template }
        var result="",next=0
        var index=template.startIndex
        while index<template.endIndex {
            let character=template[index]
            guard character == "%" else { result.append(character);index=template.index(after:index);continue }
            var cursor=template.index(after:index)
            if cursor<template.endIndex,template[cursor] == "%" {
                result.append("%");index=template.index(after:cursor);continue
            }
            var digits=""
            while cursor<template.endIndex,template[cursor].isASCII,template[cursor].isNumber {
                digits.append(template[cursor]);cursor=template.index(after:cursor)
            }
            if !digits.isEmpty {
                guard cursor<template.endIndex,template[cursor] == "$" else {
                    result.append(character);index=template.index(after:index);continue
                }
                cursor=template.index(after:cursor)
            }
            guard cursor<template.endIndex,template[cursor] == "@" else {
                result.append(character);index=template.index(after:index);continue
            }
            let position:Int
            if let explicit=Int(digits) { position=explicit-1 } else { position=next;next += 1 }
            if arguments.indices.contains(position) { result += arguments[position] }
            index=template.index(after:cursor)
        }
        return result
    }
}
