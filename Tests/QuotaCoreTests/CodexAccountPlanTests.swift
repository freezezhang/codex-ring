import XCTest
@testable import QuotaCore

final class CodexAccountPlanTests:XCTestCase {
    func testAccountInfoKeepsOnlyEmailAndPlan() throws {
        let info=try XCTUnwrap(CodexAccountInfo.parse(["account":["type":"chatgpt","email":" user@example.com ","planType":"prolite","accessToken":"secret-test-token","accountId":"private-test-id"]]))
        XCTAssertEqual(info.email,"user@example.com");XCTAssertEqual(info.plan,.prolite)
        XCTAssertFalse(String(reflecting:info).contains("secret-test-token"))
        XCTAssertFalse(String(reflecting:info).contains("private-test-id"))
    }
    func testMissingEmailAndUnknownPlanRemainIndependent() throws {
        let noEmail=try XCTUnwrap(CodexAccountInfo.parse(["account":["type":"chatgpt","email":NSNull(),"planType":"prolite"]]))
        XCTAssertNil(noEmail.email);XCTAssertEqual(noEmail.plan,.prolite)
        let unknown=try XCTUnwrap(CodexAccountInfo.parse(["account":["type":"chatgpt","email":"user@example.com","planType":"future"]]))
        XCTAssertEqual(unknown.email,"user@example.com");XCTAssertNil(unknown.plan)
        XCTAssertNil(CodexAccountInfo.parse(["account":["type":"apiKey","email":"user@example.com"]]))
        XCTAssertNil(CodexAccountInfo.parse(["account":NSNull()]))
    }
    func testMalformedEmailCannotCreateMultilineHeader() {
        for email in ["", "   ", "user\n@example.com", String(repeating:"x",count:321)] {
            XCTAssertNil(CodexAccountInfo.parse(["account":["type":"chatgpt","email":email,"planType":"prolite"]])?.email)
        }
    }
    func testProPlansProvideFullCycleExpectedAllowances() {
        for (raw,amount) in [("prolite",100.0),("pro",200.0),("promax",500.0)] {
            let plan=CodexAccountPlan.parse(["account":["type":"chatgpt","planType":raw,"email":"private-test-value"]])
            XCTAssertEqual(plan?.expectedAPICredits,amount)
            XCTAssertFalse(String(reflecting:plan).contains("private-test-value"))
        }
        XCTAssertEqual(CodexAccountPlan.prolite.title,"Pro 5x")
    }
    func testUnknownBusinessAndAPIKeyAccountsDoNotInventAllowance() {
        for raw in ["free","plus","business","team","self_serve_business_prolite","future_pro"] {
            let plan=CodexAccountPlan.parse(["account":["type":"chatgpt","planType":raw]])
            XCTAssertNil(plan?.expectedAPICredits)
        }
        XCTAssertNil(CodexAccountPlan.parse(["account":["type":"apiKey","planType":"prolite"]]))
        XCTAssertNil(CodexAccountPlan.parse(["account":NSNull()]))
    }
    func testManualOverrideAndClearingBackToAutomaticSurvivePersistence() throws {
        var config=OpenAIUsageConfiguration()
        XCTAssertEqual(config.expectedAmount(plan:.prolite),100)
        config.manualBudget=42.5
        let restored=try JSONDecoder().decode(OpenAIUsageConfiguration.self,from:JSONEncoder().encode(config))
        XCTAssertEqual(restored.expectedAmount(plan:.prolite),42.5)
        config.manualBudget=nil
        XCTAssertEqual(config.expectedAmount(plan:.promax),500)
        XCTAssertNil(config.expectedAmount(plan:nil))
        XCTAssertNil(try JSONDecoder().decode(OpenAIUsageConfiguration.self,from:JSONEncoder().encode(config)).manualBudget)
    }
    func testChangingPlanRecomputesExpectedProgressWithoutPretendingCostsWereRefreshed() {
        let date=Date(timeIntervalSince1970:1000)
        let snapshot=OpenAIUsageSnapshot(spent:25,budget:100,manualBudget:false,fetchedAt:date,periodStart:date,periodEnd:date.addingTimeInterval(86400))
        let changed=snapshot.withExpectedAmount(200,manual:false)
        XCTAssertEqual(changed.usedPercent,12.5);XCTAssertEqual(changed.spent,25);XCTAssertEqual(changed.fetchedAt,date)
        let unknown=changed.withExpectedAmount(nil,manual:false)
        XCTAssertNil(unknown.usedPercent);XCTAssertNotNil(unknown.budgetNotice)
    }
}
