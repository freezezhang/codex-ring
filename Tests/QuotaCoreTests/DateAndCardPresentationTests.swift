import XCTest
@testable import QuotaCore

final class DateAndCardPresentationTests:XCTestCase {
    func date(_ text:String)throws->Date { try XCTUnwrap(ISO8601DateFormatter().date(from:text)) }
    func testDatesUseOneDottedFormatAndBeijingMinutePrecision()throws {
        let cases=[
            ("2026-11-06T16:02:59Z","2026.11.07 00:02"),
            ("2026-11-06T23:39:00Z","2026.11.07 07:39"),
            ("2026-12-31T16:00:00Z","2027.01.01 00:00")
        ]
        for (input,expected) in cases { XCTAssertEqual(QuotaDateText.string(try date(input)),expected) }
        XCTAssertEqual(QuotaDateText.string(try date("2026-11-06T16:02:59Z"),includeSeconds:true),"2026.11.07 00:02:59")
    }
    func testMissingDateNeverInventsExpiry() { XCTAssertEqual(QuotaDateText.string(nil),"—") }
    func testCardExpiryColorsUseInclusiveRollingHourBoundaries() {
        let now=Date(timeIntervalSince1970:1793700000)
        let cases:[(TimeInterval,ResetCardExpiryBand)]=[
            (7*24*3600+1,.normal),(7*24*3600,.yellow),
            (72*3600+1,.yellow),(72*3600,.orange),
            (24*3600+1,.orange),(24*3600,.red),(0,.red),(-1,.red)
        ]
        for (remaining,expected) in cases {
            XCTAssertEqual(ResetCardExpiryBand(expiresAt:now.addingTimeInterval(remaining),now:now),expected)
        }
        XCTAssertEqual(ResetCardExpiryBand(expiresAt:nil,now:now),.normal)
    }
    func testCardTitleLocalizesFullResetWithoutRenamingOtherKinds() {
        XCTAssertEqual(ResetCard(title:" Full \n reset ",expiresAt:nil,status:"available").displayTitle,"完全重置")
        XCTAssertEqual(ResetCard(title:"FULL_RESET",expiresAt:nil,status:"available").displayTitle,"完全重置")
        XCTAssertEqual(ResetCard(title:"完全重置",expiresAt:nil,status:"available").displayTitle,"完全重置")
        XCTAssertEqual(ResetCard(title:"其他\n类型",expiresAt:nil,status:"available").displayTitle,"其他 类型")
        XCTAssertEqual(ResetCard(title:"  ",expiresAt:nil,status:"available").displayTitle,"额度重置卡")
    }
    func testCardExpiryIsSingleLineAndHandlesPastAndUnknown()throws {
        let expiry=try date("2026-11-06T23:39:00Z")
        let card=ResetCard(title:"Full reset",expiresAt:expiry,status:"available")
        XCTAssertEqual(card.expiryText(now:expiry.addingTimeInterval(-1)),"将于 2026.11.07 07:39 到期")
        XCTAssertEqual(card.expiryText(now:expiry),"已于 2026.11.07 07:39 到期")
        XCTAssertFalse(card.expiryText(now:expiry).contains("\n"))
        XCTAssertEqual(ResetCard(title:"Full reset",expiresAt:nil,status:"available").expiryText(now:expiry),"到期时间未知")
    }
}
