import XCTest
@testable import QuotaCore

final class OpenAIUsageTests:XCTestCase {
    private let now=Date(timeIntervalSince1970:1793966400)
    private func costs(_ value:Double,next:String?=nil,currency:String="usd")->String {
        """
        {"data":[{"results":[{"object":"organization.costs.result","amount":{"value":\(value),"currency":"\(currency)"}}]}],"has_more":\(next != nil),"next_page":\(next.map{"\"\($0)\""} ?? "null")}
        """
    }
    private final class Stub {
        var requests=[URLRequest]()
        var replies:[(Int,String)]
        init(_ replies:[(Int,String)]) { self.replies=replies }
        func send(_ request:URLRequest) async throws -> (Data,HTTPURLResponse) {
            requests.append(request)
            guard !replies.isEmpty else { throw OpenAIUsageError.incomplete }
            let reply=replies.removeFirst()
            return (Data(reply.1.utf8),HTTPURLResponse(url:request.url!,statusCode:reply.0,httpVersion:nil,headerFields:nil)!)
        }
    }
    func testCostsArePaginatedWithMatchingProjectAndPeriod() async throws {
        let stub=Stub([(200,costs(10,next:"next")),(200,costs(2.5))])
        var config=OpenAIUsageConfiguration();config.projectID="proj_test";config.manualBudget=50;config.cycleStartDay=7
        let value=try await OpenAIUsageClient(transport:stub.send).fetch(key:"fixture-key",configuration:config,now:now)
        XCTAssertEqual(value.spent,12.5);XCTAssertEqual(value.budget,50);XCTAssertEqual(value.usedPercent,25)
        XCTAssertEqual(stub.requests.count,2)
        let query=URLComponents(url:stub.requests[1].url!,resolvingAgainstBaseURL:false)!.queryItems!
        XCTAssertTrue(query.contains(URLQueryItem(name:"project_ids",value:"proj_test")))
        XCTAssertTrue(query.contains(URLQueryItem(name:"page",value:"next")))
        XCTAssertTrue(query.contains(URLQueryItem(name:"start_time",value:String(Int(OpenAIUsageClient.period(at:now,startDay:7).start.timeIntervalSince1970)))))
        XCTAssertTrue(stub.requests.allSatisfy{$0.url?.host == "api.openai.com" && $0.httpMethod == "GET"})
    }
    func testAutomaticAllowanceUsesPlanWhileCostStillComesFromAPI() async throws {
        let stub=Stub([(200,costs(12.5))])
        let value=try await OpenAIUsageClient(transport:stub.send).fetch(key:"fixture",configuration:.init(),plan:.prolite,now:now)
        XCTAssertEqual(value.budget,100);XCTAssertEqual(value.spent,12.5)
        XCTAssertEqual(value.usedPercent,12.5);XCTAssertFalse(value.manualBudget)
        XCTAssertEqual(stub.requests.count,1)
    }
    func testManualBudgetDoesNotRequestOrModifyOfficialLimitAndAllowsOverage() async throws {
        let stub=Stub([(200,costs(75))]);var config=OpenAIUsageConfiguration();config.manualBudget=50
        let value=try await OpenAIUsageClient(transport:stub.send).fetch(key:"fixture",configuration:config,now:now)
        XCTAssertEqual(value.usedPercent,150);XCTAssertTrue(value.manualBudget);XCTAssertEqual(stub.requests.count,1)
    }
    func testMissingBudgetStillShowsCostsWithoutInventingPercentage() async throws {
        let stub=Stub([(200,costs(12.5))])
        let value=try await OpenAIUsageClient(transport:stub.send).fetch(key:"fixture",configuration:.init(),now:now)
        XCTAssertEqual(value.spent,12.5);XCTAssertNil(value.budget);XCTAssertNil(value.usedPercent);XCTAssertNotNil(value.budgetNotice)
    }
    func testAuthorizationAndPartialPaginationFailuresDoNotBecomeZeroSpend() async throws {
        for replies in [[(401,"secret server body")],[(403,"{}")],[(200,costs(1,next:"next")),(500,"{}")],[(200,costs(1,next:"repeat")),(200,costs(2,next:"repeat"))]] {
            let stub=Stub(replies)
            do {
                _=try await OpenAIUsageClient(transport:stub.send).fetch(key:"fixture",configuration:.init(),now:now)
                XCTFail("Failed request must not produce a successful snapshot")
            } catch { XCTAssertTrue(error is OpenAIUsageError);XCTAssertFalse(error.localizedDescription.contains("secret")) }
        }
    }
    func testMalformedCostsAndNonDollarAmountsFailClosed() async throws {
        for body in ["{}",costs(10,currency:"eur"),"{\"data\":[{\"results\":[{\"object\":\"organization.costs.result\"}]}],\"has_more\":false}"] {
            do {
                _=try await OpenAIUsageClient(transport:Stub([(200,body)]).send).fetch(key:"fixture",configuration:.init(),now:now)
                XCTFail("Malformed response must not appear as zero")
            } catch { XCTAssertTrue(error is OpenAIUsageError) }
        }
    }
    func testEmptyUsageIsValidZeroAndZeroBudgetHasNoDivisionByZero() async throws {
        let stub=Stub([(200,"{\"data\":[],\"has_more\":false}")])
        var config=OpenAIUsageConfiguration();config.manualBudget=0
        let value=try await OpenAIUsageClient(transport:stub.send).fetch(key:"fixture",configuration:config,now:now)
        XCTAssertEqual(value.spent,0);XCTAssertNil(value.usedPercent)
    }
    func testSeventhDayCycleAndSnapshotExpireAtRollover() {
        let formatter=ISO8601DateFormatter()
        let instant=formatter.date(from:"2026-12-07T00:00:00Z")!
        let previous=OpenAIUsageClient.period(at:instant.addingTimeInterval(-1),startDay:7,timeZone:TimeZone(secondsFromGMT:0)!)
        XCTAssertEqual(previous.start,formatter.date(from:"2026-11-07T00:00:00Z"))
        XCTAssertEqual(previous.end,instant)
        let value=OpenAIUsageSnapshot(spent:20,budget:50,manualBudget:true,fetchedAt:instant.addingTimeInterval(-1),periodStart:previous.start,periodEnd:previous.end)
        XCTAssertTrue(value.isCurrent(at:instant.addingTimeInterval(-1)))
        XCTAssertFalse(value.isCurrent(at:instant))
    }
    func testShortMonthsClampWithoutDriftingAndRespectLocalMidnight() {
        let formatter=ISO8601DateFormatter(),zone=TimeZone(identifier:"Asia/Shanghai")!
        let february=OpenAIUsageClient.period(at:formatter.date(from:"2026-03-01T00:00:00Z")!,startDay:31,timeZone:zone)
        XCTAssertEqual(february.start,formatter.date(from:"2026-02-27T16:00:00Z"))
        XCTAssertEqual(february.end,formatter.date(from:"2026-03-30T16:00:00Z"))
        let leap=OpenAIUsageClient.period(at:formatter.date(from:"2028-03-01T00:00:00Z")!,startDay:31,timeZone:zone)
        XCTAssertEqual(leap.start,formatter.date(from:"2028-02-28T16:00:00Z"))
    }
    func testInvalidProjectCannotChangeRequestPath() async throws {
        let stub=Stub([]);var config=OpenAIUsageConfiguration();config.projectID="proj_x/../../other"
        do { _=try await OpenAIUsageClient(transport:stub.send).fetch(key:"fixture",configuration:config,now:now);XCTFail() }
        catch { XCTAssertEqual(stub.requests.count,0) }
    }
}
