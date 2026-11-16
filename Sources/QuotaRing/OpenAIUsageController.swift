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

enum OpenAIUsageStatus:Equatable {
    case notConfigured,invalidBudget,keyWhitespace,keyRequired,keychainUnavailable,keychainDeleteFailed
    case saved,configureKey,refreshing,connected,connectionFailed
    case failed(OpenAIUsageError)
    var text:String {
        switch self {
        case .notConfigured:return L10n.string("api.status.notConfigured")
        case .invalidBudget:return L10n.string("api.status.invalidBudget")
        case .keyWhitespace:return L10n.string("api.status.keyWhitespace")
        case .keyRequired:return L10n.string("api.status.keyRequired")
        case .keychainUnavailable:return L10n.string("api.status.keychainUnavailable")
        case .keychainDeleteFailed:return L10n.string("api.status.keychainDeleteFailed")
        case .saved:return L10n.string("api.status.saved")
        case .configureKey:return L10n.string("api.status.configureKey")
        case .refreshing:return L10n.string("common.refreshing")
        case .connected:return L10n.string("api.status.connected")
        case .connectionFailed:return L10n.string("api.status.connectionFailed")
        case .failed(let error):return error.errorDescription ?? L10n.string("api.status.connectionFailed")
        }
    }
}

final class OpenAIUsageController:ObservableObject {
    @Published private(set) var configuration:OpenAIUsageConfiguration
    @Published private(set) var snapshot:OpenAIUsageSnapshot?
    @Published private(set) var refreshing=false
    @Published private(set) var status:OpenAIUsageStatus = .notConfigured
    @Published private(set) var accountPlan:CodexAccountPlan?
    @Published private(set) var accountEmail:String?
    @Published private(set) var planRefreshing=false
    private let planClient=AppServerClient()
    private var lastPlanRefresh:Date?
    var expectedAmount:Double? { configuration.expectedAmount(plan:accountPlan) }
    var planTitle:String { planRefreshing && accountPlan == nil ? L10n.string("api.plan.detecting"):accountPlan?.title ?? L10n.string("api.plan.unknown") }
    var automaticAmountPrompt:String {
        accountPlan?.expectedAPICredits.map { L10n.format("api.budget.automatic",OpenAIUsageSnapshot.money($0)) } ?? L10n.string("api.budget.prompt")
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
        guard OpenAIUsageClient.validProject(project) else { status = .failed(.invalidProject);return false }
        let amount=input.isEmpty ? nil:Double(input)
        guard input.isEmpty || (amount != nil && amount!.isFinite && amount!>0) else { status = .invalidBudget;return false }
        let key=key.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !key.contains(where:{$0.isWhitespace}) else { status = .keyWhitespace;return false }
        do {
            if !key.isEmpty { try APIKeyStore.save(key) }
            guard try APIKeyStore.read() != nil else { status = .keyRequired;return false }
        } catch { status = .keychainUnavailable;return false }
        cancel();snapshot=nil
        configuration.projectID=project;configuration.manualBudget=amount;configuration.cycleStartDay=min(31,max(1,startDay));persist()
        status = .saved
        refresh()
        return true
    }
    func removeKey() {
        do { try APIKeyStore.remove() } catch { status = .keychainDeleteFailed;return }
        cancel();snapshot=nil;configuration.enabled=false;persist();status = .notConfigured
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
            guard let stored=try APIKeyStore.read(),!stored.isEmpty else { status = .configureKey;return }
            key=stored
        } catch { status = .keychainUnavailable;return }
        refreshing=true;status = .refreshing
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
                self.snapshot=resolved;self.status = .connected
            } catch {
                guard let self,self.generation == token,!Task.isCancelled else { return }
                // Never display server response bodies: they may include credentials or account metadata.
                self.snapshot=nil
                self.status=(error as? OpenAIUsageError).map { .failed($0) } ?? .connectionFailed
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
            Toggle(L10n.string("api.settings.show"),isOn:Binding(get:{controller.configuration.enabled},set:{controller.setEnabled($0)}))
                .help(L10n.string("api.settings.show.help"))
          }
            if controller.configuration.enabled {
              Section(L10n.string("api.settings.connection")) {
                SecureField(L10n.string("api.settings.key"),text:$key,prompt:Text(L10n.string("api.settings.key.prompt")))
                    .help(L10n.string("api.settings.key.help"))
                TextField(L10n.string("api.settings.project"),text:$project,prompt:Text(L10n.string("api.settings.project.prompt")))
                    .help(L10n.string("api.settings.project.help"))
                HStack { Text(L10n.string("api.settings.status"));Spacer();Text(controller.status.text).foregroundStyle(.secondary) }
                    .fixedSize(horizontal:false,vertical:true)
              }
              Section(L10n.string("api.settings.cycle")) {
                Picker(L10n.string("api.settings.startDay"),selection:$startDay) {
                    ForEach(1...31,id:\.self) { Text(L10n.format("api.settings.startDay.option",$0)).tag($0) }
                }.id("api-cycle-day."+L10n.language.code).help(L10n.string("api.settings.startDay.help"))
                HStack {
                    Text(L10n.string("api.settings.plan"));Spacer()
                    Text(controller.planTitle).foregroundStyle(.secondary)
                    Button { controller.refreshAccountPlan() } label: { Image(systemName:"arrow.clockwise") }
                        .buttonStyle(.borderless).disabled(controller.planRefreshing).help(L10n.string("api.settings.plan.refresh"))
                }
                TextField(L10n.string("api.settings.budget"),text:$budget,prompt:Text(controller.automaticAmountPrompt))
                    .help(L10n.string("api.settings.budget.help"))
              }
              Section {
                HStack {
                    Button(L10n.string("api.settings.save")) { if controller.save(key:key,project:project,budget:budget,startDay:startDay) { key="" } }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    Button(L10n.string("api.settings.deleteKey")) { controller.removeKey();key="" }
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
                    Text(controller.configuration.projectID.isEmpty ? L10n.string("api.panel.organization"):L10n.string("api.panel.project"))
                        .font(.system(size:10)).foregroundStyle(.secondary)
                        .help(controller.configuration.projectID.isEmpty ? L10n.string("api.panel.organization.help"):controller.configuration.projectID)
                    if controller.refreshing { ProgressView().controlSize(.small) }
                }
                TimelineView(.periodic(from:.now,by:30)) { context in
                    if let data=controller.snapshot,data.isCurrent(at:context.date) {
                        details(data)
                    } else {
                        Text(controller.snapshot == nil ? controller.status.text:L10n.string("api.panel.stale"))
                            .font(.system(size:12)).foregroundStyle(.secondary)
                        if let amount=controller.expectedAmount {
                            Text(L10n.format("api.panel.total",OpenAIUsageSnapshot.money(amount))).font(.system(size:12)).monospacedDigit()
                        }
                        Button(L10n.string("common.settings"),action:settings).buttonStyle(.borderless)
                    }
                }
              }
            }
        }
    }
    private func details(_ data:OpenAIUsageSnapshot)->some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(alignment:.firstTextBaseline) {
                Text(L10n.format("api.panel.spent",OpenAIUsageSnapshot.money(data.spent)))
                Spacer(minLength:4)
                if let percent=data.usedPercent {
                    Text(metric.value(String(format:"%.0f%%",metric == .used ? percent:max(0,100-percent))))
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
            }.frame(height:7).accessibilityLabel(L10n.string("api.panel.progress.a11y"))
                .accessibilityValue(data.usedPercent.map { DisplayMetric.used.value(String(format:"%.0f%%",$0)) } ?? L10n.string("api.panel.noBudget"))
            HStack(alignment:.firstTextBaseline,spacing:8) {
                if let budget=data.budget {
                    Text(L10n.format("api.panel.total",OpenAIUsageSnapshot.money(budget)))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .help(data.manualBudget ? L10n.string("api.panel.total.manual.help"):L10n.string("api.panel.total.estimated.help"))
                } else { Text(data.budgetNotice ?? L10n.string("api.panel.noBudget")) }
                Spacer(minLength:0)
                Text(periodText(data)).font(.system(size:10))
                    .lineLimit(1).fixedSize(horizontal:true,vertical:false)
                    .help(L10n.format("api.panel.period.help",QuotaDateText.string(data.fetchedAt)))
            }.font(.system(size:11)).foregroundStyle(.secondary).monospacedDigit()
        }
    }
    private func periodText(_ data:OpenAIUsageSnapshot)->String {
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX")
        formatter.dateFormat="yyyy.MM.dd"
        return formatter.string(from:data.periodStart)+" – "+formatter.string(from:data.periodEnd)
    }

}
