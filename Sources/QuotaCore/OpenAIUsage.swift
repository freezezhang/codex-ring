import Foundation

public struct OpenAIUsageConfiguration:Codable,Equatable {
    public var enabled=false
    public var projectID=""
    public var cycleStartDay=7
    public var manualBudget:Double?
    public init() {}
    public func expectedAmount(plan:CodexAccountPlan?)->Double? {
        if let manualBudget { return manualBudget.isFinite && manualBudget>0 ? manualBudget:nil }
        return plan?.expectedAPICredits
    }
}

public struct OpenAIUsageSnapshot:Equatable {
    public let spent:Double
    public let budget:Double?
    public let manualBudget:Bool
    public let fetchedAt:Date
    public let periodStart:Date
    public let periodEnd:Date
    public let budgetNotice:String?
    public var usedPercent:Double? { budget.flatMap { $0>0 ? max(0,spent)/$0*100:nil } }
    public init(spent:Double,budget:Double?,manualBudget:Bool,fetchedAt:Date,periodStart:Date,periodEnd:Date,budgetNotice:String?=nil) {
        self.spent=spent;self.budget=budget;self.manualBudget=manualBudget;self.fetchedAt=fetchedAt
        self.periodStart=periodStart;self.periodEnd=periodEnd;self.budgetNotice=budgetNotice
    }
    public func isCurrent(at now:Date)->Bool { now>=periodStart && now<periodEnd && now.timeIntervalSince(fetchedAt)<900 }
    public func withExpectedAmount(_ amount:Double?,manual:Bool)->Self {
        Self(spent:spent,budget:amount,manualBudget:manual,fetchedAt:fetchedAt,periodStart:periodStart,periodEnd:periodEnd,
             budgetNotice:amount == nil ? "未识别到总额度，请在设置中填写":nil)
    }
    public static func money(_ value:Double)->String { String(format:"$%.2f",locale:Locale(identifier:"en_US_POSIX"),value) }
}

public enum OpenAIUsageError:Error,LocalizedError {
    case authorization,permission,rateLimited,server,invalidResponse,invalidProject,incomplete
    public var errorDescription:String? {
        switch self {
        case .authorization:return "Key 无效或已过期"
        case .permission:return "需要有查询权限的 Admin API Key"
        case .rateLimited:return "请求过于频繁，请稍后刷新"
        case .server:return "OpenAI 服务暂不可用"
        case .invalidResponse:return "费用数据格式异常"
        case .invalidProject:return "项目 ID 格式不正确"
        case .incomplete:return "费用数据不完整，请重新刷新"
        }
    }
}

public struct OpenAIUsageClient {
    public typealias Transport=(URLRequest) async throws -> (Data,HTTPURLResponse)
    private let transport:Transport
    public init(transport:@escaping Transport) { self.transport=transport }
    /// Monthly boundaries follow the user's local calendar. Missing dates (e.g. February 31)
    /// use that month's final day without shifting subsequent months to that date.
    public static func period(at now:Date,startDay:Int,timeZone:TimeZone = .current)->DateInterval {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=timeZone
        let month=calendar.dateInterval(of:.month,for:now)!.start
        let day=min(31,max(1,startDay))
        func boundary(_ first:Date)->Date {
            let last=calendar.range(of:.day,in:.month,for:first)!.count
            return calendar.date(byAdding:.day,value:min(day,last)-1,to:first)!
        }
        let current=boundary(month)
        if now>=current {
            return DateInterval(start:current,end:boundary(calendar.date(byAdding:.month,value:1,to:month)!))
        }
        return DateInterval(start:boundary(calendar.date(byAdding:.month,value:-1,to:month)!),end:current)
    }
    public static func validProject(_ value:String)->Bool {
        value.isEmpty || (value.hasPrefix("proj_") && value.count>5 && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"_-" )).contains($0) })
    }
    public func fetch(key:String,configuration:OpenAIUsageConfiguration,plan:CodexAccountPlan?=nil,now:Date=Date()) async throws -> OpenAIUsageSnapshot {
        guard Self.validProject(configuration.projectID) else { throw OpenAIUsageError.invalidProject }
        let period=Self.period(at:now,startDay:configuration.cycleStartDay)
        var total=0.0,cursor:String?
        var seen=Set<String>()
        for pageIndex in 0..<100 {
            try Task.checkCancellation()
            var query=[URLQueryItem(name:"start_time",value:String(Int(period.start.timeIntervalSince1970))),
                       URLQueryItem(name:"end_time",value:String(Int(now.timeIntervalSince1970))),
                       URLQueryItem(name:"bucket_width",value:"1d"),URLQueryItem(name:"limit",value:"31")]
            if !configuration.projectID.isEmpty { query.append(URLQueryItem(name:"project_ids",value:configuration.projectID)) }
            if let cursor { query.append(URLQueryItem(name:"page",value:cursor)) }
            let (bytes,response)=try await request("organization/costs",query:query,key:key)
            try validate(response.statusCode)
            let page:CostPage
            do { page=try JSONDecoder().decode(CostPage.self,from:bytes) } catch { throw OpenAIUsageError.invalidResponse }
            for bucket in page.data {
                for result in bucket.results {
                    guard result.object == "organization.costs.result",result.amount.currency.lowercased() == "usd",result.amount.value.isFinite else { throw OpenAIUsageError.invalidResponse }
                    total += result.amount.value
                }
            }
            if !page.has_more { break }
            guard let next=page.next_page,!next.isEmpty,seen.insert(next).inserted,pageIndex<99 else { throw OpenAIUsageError.incomplete }
            cursor=next
        }
        guard total.isFinite else { throw OpenAIUsageError.invalidResponse }
        let budget=configuration.expectedAmount(plan:plan)
        let notice:String?=budget == nil ? "未识别到总额度，请在设置中填写":nil
        try Task.checkCancellation()
        return OpenAIUsageSnapshot(spent:total,budget:budget,manualBudget:configuration.manualBudget != nil,fetchedAt:now,periodStart:period.start,periodEnd:period.end,budgetNotice:notice)
    }
    private func request(_ path:String,query:[URLQueryItem]=[],key:String) async throws -> (Data,HTTPURLResponse) {
        var components=URLComponents(string:"https://api.openai.com/v1/"+path)!
        if !query.isEmpty { components.queryItems=query }
        var request=URLRequest(url:components.url!);request.timeoutInterval=30
        request.setValue("Bearer "+key,forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        return try await transport(request)
    }
    private func validate(_ status:Int)throws {
        switch status {
        case 200..<300:return
        case 401:throw OpenAIUsageError.authorization
        case 403:throw OpenAIUsageError.permission
        case 429:throw OpenAIUsageError.rateLimited
        case 500...599:throw OpenAIUsageError.server
        default:throw OpenAIUsageError.invalidResponse
        }
    }
    private struct CostPage:Decodable {
        let data:[Bucket];let has_more:Bool;let next_page:String?
        struct Bucket:Decodable { let results:[Cost] }
        struct Cost:Decodable { let object:String;let amount:Amount }
        struct Amount:Decodable { let value:Double;let currency:String }
    }
}
