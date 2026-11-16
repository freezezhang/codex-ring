import AppKit
import SwiftUI
import Security
import QuotaCore

private enum APIKeyStore {
    private static var query:[String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.freeze.codex-quota-ring.openai-admin",kSecAttrAccount as String:"usage"] }
    static func read()throws->String? {
        var q=query;q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?
        let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,let data=result as? Data,let key=String(data:data,encoding:.utf8) else { throw KeyError() }
        return key
    }
    static func save(_ key:String)throws {
        let value=[kSecValueData as String:Data(key.utf8)]
        let status=SecItemUpdate(query as CFDictionary,value as CFDictionary)
        if status == errSecItemNotFound {
            var q=query;q[kSecValueData as String]=Data(key.utf8)
            q[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(q as CFDictionary,nil) == errSecSuccess else { throw KeyError() }
        } else if status != errSecSuccess { throw KeyError() }
    }
    static func remove()throws {
        let status=SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeyError() }
    }
    struct KeyError:Error {}
}
private final class APIUsageSessionDelegate:NSObject,URLSessionTaskDelegate {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) { completionHandler(nil) }
}

final class OpenAIUsageController:ObservableObject {
    @Published private(set) var configuration:OpenAIUsageConfiguration
    @Published private(set) var snapshot:OpenAIUsageSnapshot?
    @Published private(set) var refreshing=false
    @Published private(set) var status="未配置 Admin API Key"
    @Published private(set) var accountPlan:CodexAccountPlan?
    @Published private(set) var accountEmail:String?
    @Published private(set) var planRefreshing=false
    private let planClient=AppServerClient()
    private var lastPlanRefresh:Date?
    var expectedAmount:Double? { configuration.expectedAmount(plan:accountPlan) }
    var planTitle:String { planRefreshing && accountPlan == nil ? "正在识别…":accountPlan?.title ?? "未识别" }
    var automaticAmountPrompt:String {
        accountPlan?.expectedAPICredits.map { "自动 · "+OpenAIUsageSnapshot.money($0) } ?? "留空自动识别套餐"
    }
    private var task:Task<Void,Never>?
    private var generation=UUID()
    private var timer:Timer?
    private let storageKey="openAIUsageConfiguration"
    private let session:URLSession
    init() {
        configuration=UserDefaults.standard.data(forKey:storageKey).flatMap { try? JSONDecoder().decode(OpenAIUsageConfiguration.self,from:$0) } ?? OpenAIUsageConfiguration()
        let config=URLSessionConfiguration.ephemeral
        config.httpCookieStorage=nil;config.httpShouldSetCookies=false;config.urlCredentialStorage=nil;config.urlCache=nil
        session=URLSession(configuration:config,delegate:APIUsageSessionDelegate(),delegateQueue:nil)
        timer=Timer.scheduledTimer(withTimeInterval:300,repeats:true) { [weak self] _ in
            guard let self else { return }
            self.refreshAccountPlan();self.refresh()
        }
        refreshAccountPlan()
        if configuration.enabled { refresh() }
    }
    deinit { task?.cancel();planClient.cancel();timer?.invalidate();session.invalidateAndCancel() }
    func setEnabled(_ enabled:Bool) {
        cancel();configuration.enabled=enabled;persist()
        if enabled { refreshAccountPlan();refresh() }
    }
    @discardableResult func save(key:String,project:String,budget:String,startDay:Int)->Bool {
        let project=project.trimmingCharacters(in:.whitespacesAndNewlines)
        let input=budget.trimmingCharacters(in:.whitespacesAndNewlines)
        guard OpenAIUsageClient.validProject(project) else { status="项目 ID 格式不正确";return false }
        let amount=input.isEmpty ? nil:Double(input)
        guard input.isEmpty || (amount != nil && amount!.isFinite && amount!>0) else { status="总额度需填写大于 0 的美元金额";return false }
        let key=key.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !key.contains(where:{$0.isWhitespace}) else { status="Key 不能包含空格或换行";return false }
        do {
            if !key.isEmpty { try APIKeyStore.save(key) }
            guard try APIKeyStore.read() != nil else { status="请填写 Admin API Key";return false }
        } catch { status="无法访问钥匙串";return false }
        cancel();snapshot=nil
        configuration.projectID=project;configuration.manualBudget=amount;configuration.cycleStartDay=min(31,max(1,startDay));persist()
        status="配置已保存"
        refresh()
        return true
    }
    func removeKey() {
        do { try APIKeyStore.remove() } catch { status="无法删除钥匙串中的 Key";return }
        cancel();snapshot=nil;configuration.enabled=false;persist();status="未配置 Admin API Key"
    }
    func refreshAccountPlan() {
        guard !planRefreshing else { return }
        planRefreshing=true
        let client=planClient
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let account=client.fetchAccountInfo()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.accountEmail=account?.email;self.accountPlan=account?.plan
                self.planRefreshing=false;self.lastPlanRefresh=Date()
                if let snapshot=self.snapshot {
                    self.snapshot=snapshot.withExpectedAmount(self.expectedAmount,manual:self.configuration.manualBudget != nil)
                }
            }
        }
    }
    private func persist() { if let data=try? JSONEncoder().encode(configuration) { UserDefaults.standard.set(data,forKey:storageKey) } }
    private func cancel() { generation=UUID();task?.cancel();task=nil;refreshing=false }
    func refreshIfNeeded() {
        if lastPlanRefresh.map({Date().timeIntervalSince($0)>=300}) ?? true { refreshAccountPlan() }
        if snapshot.map({ Date().timeIntervalSince($0.fetchedAt)>=300 || !$0.isCurrent(at:Date()) }) ?? true { refresh() }
    }
    func refresh() {
        guard configuration.enabled,!refreshing else { return }
        let key:String
        do {
            guard let stored=try APIKeyStore.read(),!stored.isEmpty else { status="请在设置中配置 Admin API Key";return }
            key=stored
        } catch { status="无法访问钥匙串";return }
        refreshing=true;status="正在刷新…"
        let token=generation,config=configuration,session=session
        task=Task { @MainActor [weak self] in
            let client=OpenAIUsageClient { request in
                let (data,response)=try await session.data(for:request)
                guard let response=response as? HTTPURLResponse else { throw OpenAIUsageError.invalidResponse }
                return (data,response)
            }
            do {
                let result=try await client.fetch(key:key,configuration:config)
                guard let self,self.generation == token,!Task.isCancelled else { return }
                let resolved=result.withExpectedAmount(self.expectedAmount,manual:self.configuration.manualBudget != nil)
                self.snapshot=resolved;self.status="已连接"
            } catch {
                guard let self,self.generation == token,!Task.isCancelled else { return }
                // Never display server response bodies: they may include credentials or account metadata.
                self.snapshot=nil
                self.status=(error as? OpenAIUsageError)?.errorDescription ?? "连接失败，请稍后重试"
            }
            guard let self,self.generation == token else { return }
            self.refreshing=false;self.task=nil
        }
    }
}

struct OpenAIUsageSettings:View {
    @ObservedObject var controller:OpenAIUsageController
    @State private var key=""
    @State private var project=""
    @State private var budget=""
    @State private var startDay=7
    var body:some View {
        Group {
          Section {
            Toggle("显示 API 使用进度",isOn:Binding(get:{controller.configuration.enabled},set:{controller.setEnabled($0)}))
                .help("仅在菜单面板显示。按自定义月度周期统计，每5分钟刷新；官方统计可能延迟。")
          }
            if controller.configuration.enabled {
              Section("连接") {
                SecureField("Admin API Key",text:$key,prompt:Text("留空保留已保存的 Key"))
                    .help("需要有费用查询权限的 OpenAI Admin API Key，普通模型 Key 不适用。仅存储在本机钥匙串。")
                TextField("项目 ID",text:$project,prompt:Text("留空统计整个组织"))
                    .help("填写 proj_ 开头的项目 ID，只统计该项目费用；留空统计组织总费用。")
                HStack { Text("连接状态");Spacer();Text(controller.status).foregroundStyle(.secondary) }
                    .fixedSize(horizontal:false,vertical:true)
              }
              Section("周期与额度") {
                Picker("周期起始日",selection:$startDay) {
                    ForEach(1...31,id:\.self) { Text("每月 \($0) 日").tag($0) }
                }.help("按系统时区的零点开始；当月没有该日期时取月底。订阅扣款日无法自动读取。")
                HStack {
                    Text("订阅套餐");Spacer()
                    Text(controller.planTitle).foregroundStyle(.secondary)
                    Button { controller.refreshAccountPlan() } label: { Image(systemName:"arrow.clockwise") }
                        .buttonStyle(.borderless).disabled(controller.planRefreshing).help("重新识别订阅套餐")
                }
                TextField("总额度（美元）",text:$budget,prompt:Text(controller.automaticAmountPrompt))
                    .help("留空按已识别的 Pro 套餐使用完整周期的预期 API 额度；输入金额可手动覆盖，清空恢复自动。需要已领取福利并绑定当前 API 组织。首次领取按剩余时间折算，可手动修正；这里不是实际余额。Business 套餐需手动填写。")
              }
              Section {
                HStack {
                    Button("保存并刷新") { if controller.save(key:key,project:project,budget:budget,startDay:startDay) { key="" } }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    Button("删除 Key") { controller.removeKey();key="" }
                }
              }
            }
        }.onAppear {
            if controller.configuration.enabled { controller.refreshAccountPlan() }
            startDay=controller.configuration.cycleStartDay
            project=controller.configuration.projectID
            budget=controller.configuration.manualBudget.map { String($0) } ?? ""
        }
    }
}

struct OpenAIUsagePanel:View {
    @ObservedObject var controller:OpenAIUsageController
    let metric:DisplayMetric
    let settings:()->Void
    var body:some View {
        if controller.configuration.enabled {
            QuotaSectionCard {
              VStack(alignment:.leading,spacing:16) {
                HStack(spacing:8) {
                    Text("OpenAI API").font(.system(size:15,weight:.bold)).fixedSize()
                    Spacer(minLength:0)
                    Text(controller.configuration.projectID.isEmpty ? "整个组织":"项目")
                        .font(.system(size:10)).foregroundStyle(.secondary)
                        .help(controller.configuration.projectID.isEmpty ? "统计整个 API 组织的费用":controller.configuration.projectID)
                    if controller.refreshing { ProgressView().controlSize(.small) }
                }
                TimelineView(.periodic(from:.now,by:30)) { context in
                    if let data=controller.snapshot,data.isCurrent(at:context.date) {
                        details(data)
                    } else {
                        Text(controller.snapshot == nil ? controller.status:"数据已过期，请刷新")
                            .font(.system(size:12)).foregroundStyle(.secondary)
                        if let amount=controller.expectedAmount {
                            Text("总额度 "+OpenAIUsageSnapshot.money(amount)).font(.system(size:12)).monospacedDigit()
                        }
                        Button("设置",action:settings).buttonStyle(.borderless)
                    }
                }
              }
            }
        }
    }
    private func details(_ data:OpenAIUsageSnapshot)->some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(alignment:.firstTextBaseline) {
                Text("本期已用 "+OpenAIUsageSnapshot.money(data.spent))
                Spacer(minLength:4)
                if let percent=data.usedPercent {
                    Text((metric == .used ? "已用 ":"剩余 ")+String(format:"%.0f%%",metric == .used ? percent:max(0,100-percent)))
                }
            }.font(.system(size:13,weight:.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            GeometryReader { geometry in
                let used=data.usedPercent ?? 0
                let value=data.usedPercent == nil ? 0:(metric == .used ? min(100,used):max(0,100-used))
                ZStack(alignment:.leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    Capsule().fill(used>=90 ? Color.red:used>=80 ? .orange:used>=70 ? .yellow:.blue)
                        .frame(width:geometry.size.width*value/100)
                }
            }.frame(height:7).accessibilityLabel("API 总额度进度")
                .accessibilityValue(data.usedPercent.map{String(format:"已用 %.0f%%",$0)} ?? "未设置总额度")
            HStack(alignment:.firstTextBaseline,spacing:8) {
                if let budget=data.budget {
                    Text("总额度 "+OpenAIUsageSnapshot.money(budget))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .help(data.manualBudget ? "使用手动设置的周期额度；不是实际余额。":"按订阅套餐估算的完整周期额度；首次领取可能折算，不代表已到账或剩余余额。")
                } else { Text(data.budgetNotice ?? "未设置总额度") }
                Spacer(minLength:0)
                Text(periodText(data)).font(.system(size:10))
                    .lineLimit(1).fixedSize(horizontal:true,vertical:false)
                    .help("统计周期；刷新于 "+QuotaDateText.string(data.fetchedAt))
            }.font(.system(size:11)).foregroundStyle(.secondary).monospacedDigit()
        }
    }
    private func periodText(_ data:OpenAIUsageSnapshot)->String {
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX")
        formatter.dateFormat="yyyy.MM.dd"
        return formatter.string(from:data.periodStart)+" – "+formatter.string(from:data.periodEnd)
    }

}
