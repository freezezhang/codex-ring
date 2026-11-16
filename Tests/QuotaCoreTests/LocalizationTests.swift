import XCTest
@testable import QuotaCore

final class LocalizationTests:XCTestCase {
    private let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    override func tearDown() { L10n.apply(languageCode:"zh-Hans");super.tearDown() }

    private func sources(in directories:[String])throws->[(name:String,text:String)] {
        try directories.flatMap { directory -> [(name:String,text:String)] in
            let base=root.appendingPathComponent(directory)
            let files=FileManager.default.enumerator(at:base,includingPropertiesForKeys:nil)?.compactMap { $0 as? URL } ?? []
            return try files.filter { $0.pathExtension == "swift" }.map { ($0.lastPathComponent,try String(contentsOf:$0,encoding:.utf8)) }
        }
    }
    private func matches(_ pattern:String,in text:String)->[[String]] {
        let expression=try! NSRegularExpression(pattern:pattern)
        let string=text as NSString
        return expression.matches(in:text,range:NSRange(location:0,length:string.length)).map { match in
            (0..<match.numberOfRanges).compactMap { index in
                let range=match.range(at:index)
                return range.location == NSNotFound ? nil:string.substring(with:range)
            }
        }
    }
    private func placeholders(_ value:String)->[Int] {
        var next=0
        return matches(#"%(?:(\d+)\$)?@"#,in:value.replacingOccurrences(of:"%%",with:"")).map { groups in
            if groups.count>1,let position=Int(groups[1]) { return position }
            next += 1;return next
        }.sorted()
    }

    func testRegistryMatchesBundledTablesAndPackageDefault() throws {
        let directories=try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("Sources/QuotaCore/Resources").path)
            .filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(".lproj".count)) }
        XCTAssertEqual(Set(directories),Set(AppLanguage.supported.map(\.code)))
        XCTAssertEqual(Set(AppLanguage.supported.map(\.code)).count,AppLanguage.supported.count)
        for language in AppLanguage.supported {
            XCTAssertNotNil(L10n.table(for:language.code),language.code)
            XCTAssertFalse(language.displayName.isEmpty)
        }
        let manifest=try String(contentsOf:root.appendingPathComponent("Package.swift"),encoding:.utf8)
        XCTAssertTrue(manifest.contains("defaultLocalization: \"\(AppLanguage.fallback.code)\""))
    }
    func testEveryLanguageHasTheSameKeysAndPlaceholders() throws {
        let fallback=try XCTUnwrap(L10n.tables[AppLanguage.fallback.code])
        XCTAssertFalse(fallback.isEmpty)
        for language in AppLanguage.supported {
            let table=try XCTUnwrap(L10n.tables[language.code])
            XCTAssertEqual(Set(table.keys),Set(fallback.keys),language.code)
            for (key,value) in table {
                XCTAssertEqual(placeholders(value),placeholders(fallback[key] ?? ""),"\(language.code) \(key)")
                let stray=matches(#"%(?!@|\d+\$@)"#,in:value.replacingOccurrences(of:"%%",with:""))
                XCTAssertTrue(stray.isEmpty,"\(language.code) \(key): write a literal percent sign as %%")
            }
        }
    }
    func testSourcesUseOnlyDefinedKeysAndEveryKeyIsUsed() throws {
        let fallback=try XCTUnwrap(L10n.tables[AppLanguage.fallback.code])
        var used=Set<String>()
        for file in try sources(in:["Sources","scripts"]) {
            for groups in matches(#"L10n\.(?:string|format)\((?:[^"()]*\?)?\s*"([^"]+)"(?:\s*:\s*"([^"]+)")?"#,in:file.text) {
                for key in groups.dropFirst() {
                    used.insert(key)
                    XCTAssertNotNil(fallback[key],"\(file.name) uses undefined key \(key)")
                }
            }
        }
        XCTAssertEqual(Set(fallback.keys).subtracting(used),[],"unused keys")
    }
    func testInterfaceTextIsNotHardCodedInSources() throws {
        // Codex's own control names and the registry's native names are data, not interface text.
        let allowed:Set<String>=["CodexUsageLocator.swift","Localization.swift"]
        for file in try sources(in:["Sources"]) where !allowed.contains(file.name) {
            for line in file.text.split(separator:"\n") where !line.trimmingCharacters(in:.whitespaces).hasPrefix("//") {
                for literal in matches(#""(?:[^"\\]|\\.)*""#,in:String(line)) {
                    XCTAssertTrue(matches(#"\p{Han}"#,in:literal[0]).isEmpty,"\(file.name): \(literal[0])")
                }
            }
        }
    }
    func testSystemLanguagesFollowOrderAndFallBack() {
        let fallback=AppLanguage.fallback
        let chinese=AppLanguage.registered("zh-Hans")
        XCTAssertEqual(AppLanguage.matching(preferredLanguages:["zh-Hans-CN","en-US"]),chinese)
        XCTAssertEqual(AppLanguage.matching(preferredLanguages:["zh_CN"]),chinese)
        XCTAssertEqual(AppLanguage.matching(preferredLanguages:["zh-Hant-TW"]),chinese)
        XCTAssertEqual(AppLanguage.matching(preferredLanguages:["en-GB","zh-Hans"]),AppLanguage.registered("en"))
        XCTAssertEqual(AppLanguage.matching(preferredLanguages:["ja-JP","zh-Hans-CN"]),chinese)
        XCTAssertEqual(AppLanguage.matching(preferredLanguages:["fr-FR","de-DE"]),fallback)
        XCTAssertEqual(AppLanguage.matching(preferredLanguages:[]),fallback)
    }
    func testPreferenceOverridesSystemAndUnknownCodesFollowSystem() {
        L10n.apply(languageCode:nil,preferredLanguages:["fr-FR"])
        XCTAssertEqual(L10n.language,AppLanguage.fallback)
        L10n.apply(languageCode:"zh-Hans",preferredLanguages:["fr-FR"])
        XCTAssertEqual(L10n.language.code,"zh-Hans")
        XCTAssertFalse(L10n.apply(languageCode:"zh-Hans",preferredLanguages:["fr-FR"]))
        XCTAssertTrue(L10n.apply(languageCode:"xx-unknown",preferredLanguages:["en-US"]))
        XCTAssertEqual(L10n.language.code,"en")
        XCTAssertEqual(L10n.string("missing.key"),"missing.key")
    }
    func testFormattingSupportsPositionsAndPercentSigns() {
        XCTAssertEqual(L10n.substitute("%2$@ · %1$@",["a","b"]),"b · a")
        XCTAssertEqual(L10n.substitute("%@%% of %@",["5","10"]),"5% of 10")
        XCTAssertEqual(L10n.substitute("100% sure",[]),"100% sure")
        XCTAssertEqual(L10n.substitute("%3$@",["a"]),"")
    }
    func testLanguagePreferenceIsPersistedAndOptional() throws {
        var preferences=RingPreferences()
        XCTAssertNil(preferences.languageCode)
        preferences.languageCode="en"
        let decoded=try JSONDecoder().decode(RingPreferences.self,from:JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded.languageCode,"en")
        let legacy=try JSONDecoder().decode(RingPreferences.self,from:Data(#"{"metric":"used"}"#.utf8))
        XCTAssertNil(legacy.languageCode);XCTAssertEqual(legacy.metric,.used)
    }
    func testEnglishPresentation() {
        L10n.apply(languageCode:"en")
        XCTAssertEqual(QuotaPeriod.week.value(DisplayMetric.remaining.value("55%")),"Weekly 55% left")
        XCTAssertEqual(QuotaPeriod.fiveHours.value(DisplayMetric.used.value("17.5%")),"5-hour 17.5% used")
        XCTAssertEqual(RefreshInterval.twoMinutes.title,"2 min")
        XCTAssertEqual(WeeklyPaceSchedule.five.title,"5 days")
        let now=Date(timeIntervalSince1970:1_800_000_000)
        let row=QuotaMenuRow(period:.week,used:20,usedText:"20%",remainingText:"80%",statusText:"",resetText:"",
                             resetsAt:now.addingTimeInterval(93784),paceValidUntil:nil,panel:QuotaPanelPreferences(),metric:.remaining)
        XCTAssertEqual(row.progressText,"80% left")
        XCTAssertEqual(row.resetCountdown(at:now),"Resets in 1d 2h 3m 4s")
        XCTAssertEqual(QuotaMenuCardRow(text:"",expiryBand:.red,expiresAt:now.addingTimeInterval(3661)).displayText(at:now),"1h 1m 1s")
        XCTAssertEqual(ResetCard(title:"",expiresAt:nil,status:"available").displayTitle,"Quota reset card")
        XCTAssertEqual(OpenAIUsageError.invalidProject.errorDescription,"Invalid project ID format")
    }
    func testRequiredAccessibilityUpdateNoticeIsPreserved() {
        XCTAssertEqual(L10n.raw("overlay.updateNotice",language:AppLanguage.registered("zh-Hans")!),
                       "应用已更新，旧授权可能已失效，请删除旧版本授权，重新授权。")
    }
}
