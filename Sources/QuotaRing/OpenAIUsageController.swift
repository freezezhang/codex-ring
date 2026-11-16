import AppKit
import SwiftUI
import Security
import QuotaCore

protocol APIKeyStorage {
    func read() throws -> String?
    func save(_ key:String) throws
    func remove() throws
}

private struct APIKeyStore:APIKeyStorage {
    private static var query:[String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.freeze.codex-quota-ring.openai-admin",kSecAttrAccount as String:"usage"] }
    func read()throws->String? {
        var q=Self.query;q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?
        let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,let data=result as? Data,let key=String(data:data,encoding:.utf8) else { throw KeyError() }
        return key
    }
    func save(_ key:String)throws {
        let value=[kSecValueData as String:Data(key.utf8)]
        let status=SecItemUpdate(Self.query as CFDictionary,value as CFDictionary)
        if status == errSecItemNotFound {
            var q=Self.query;q[kSecValueData as String]=Data(key.utf8)
            q[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(q as CFDictionary,nil) == errSecSuccess else { throw KeyError() }
        } else if status != errSecSuccess { throw KeyError() }
    }
    func remove()throws {
        let status=SecItemDelete(Self.query as CFDictionary)
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
    @Published private(set) var hasConfiguredKey=false
    @Published private(set) var snapshot:OpenAIUsageSnapshot?
    @Published private(set) var refreshing=false
    @Published private(set) var status:OpenAIUsageStatus = .notConfigured
    @Published private(set) var accountPlan:CodexAccountPlan?
    @Published private(set) var accountEmail:String?
    @Published private(set) var planRefreshing=false
    @Published private(set) var keychainBusy=false
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
    private let defaults:UserDefaults
    private let keyStore:APIKeyStorage
    private let keyQueue=DispatchQueue(label:"local.freeze.codex-ring.keychain",qos:.utility)
    init(defaults:UserDefaults = .standard,keyStore:APIKeyStorage? = nil,automaticRefresh:Bool = true) {
        self.defaults=defaults;self.keyStore=keyStore ?? APIKeyStore()
        configuration=defaults.data(forKey:storageKey).flatMap { try? JSONDecoder().decode(OpenAIUsageConfiguration.self,from:$0) } ?? OpenAIUsageConfiguration()
        let config=URLSessionConfiguration.ephemeral
        config.httpCookieStorage=nil;config.httpShouldSetCookies=false;config.urlCredentialStorage=nil;config.urlCache=nil
        session=URLSession(configuration:config,delegate:APIUsageSessionDelegate(),delegateQueue:nil)
        guard automaticRefresh else { return }
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
    func save(key:String,project:String,budget:String,startDay:Int,completion:@escaping (Bool)->Void) {
        guard !keychainBusy else { completion(false);return }
        let project=project.trimmingCharacters(in:.whitespacesAndNewlines)
        let input=budget.trimmingCharacters(in:.whitespacesAndNewlines)
        guard OpenAIUsageClient.validProject(project) else { status = .failed(.invalidProject);completion(false);return }
        let amount=input.isEmpty ? nil:Double(input)
        guard input.isEmpty || (amount != nil && amount!.isFinite && amount!>0) else { status = .invalidBudget;completion(false);return }
        let key=key.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !key.contains(where:{$0.isWhitespace}) else { status = .keyWhitespace;completion(false);return }
        cancel()
        performKeyOperation({ store in
            if !key.isEmpty { try store.save(key) }
            return try store.read().map { !$0.isEmpty } ?? false
        }) { [weak self] result in
            guard let self else { completion(false);return }
            switch result {
            case .failure:self.status = .keychainUnavailable;completion(false)
            case .success(let exists):
                self.hasConfiguredKey=exists
                guard exists else { self.status = .keyRequired;completion(false);return }
                self.snapshot=nil
                self.configuration.projectID=project;self.configuration.manualBudget=amount
                self.configuration.cycleStartDay=min(31,max(1,startDay));self.persist()
                self.status = .saved;completion(true);self.refresh()
            }
        }
    }
    func removeKey() {
        guard !keychainBusy else { return }
        cancel()
        performKeyOperation({ try $0.remove() }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:self.status = .keychainDeleteFailed
            case .success:
                self.snapshot=nil;self.hasConfiguredKey=false;self.configuration.enabled=false
                self.persist();self.status = .notConfigured
            }
        }
    }
    // Security calls can wait for an unlocked keychain or user authorization.
    // Keep them off the UI thread, and allow only one operation in flight.
    private func performKeyOperation<Value>(_ operation:@escaping (APIKeyStorage)throws->Value,
                                            completion:@escaping (Result<Value,Error>)->Void) {
        keychainBusy=true
        let store=keyStore
        keyQueue.async { [weak self] in
            let result=Result { try operation(store) }
            DispatchQueue.main.async { [weak self] in
                self?.keychainBusy=false
                completion(result)
            }
        }
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
    private func persist() { if let data=try? JSONEncoder().encode(configuration) { defaults.set(data,forKey:storageKey) } }
    private func cancel() { generation=UUID();task?.cancel();task=nil;refreshing=false }
    func refreshIfNeeded() {
        if lastPlanRefresh.map({Date().timeIntervalSince($0)>=300}) ?? true { refreshAccountPlan() }
        if snapshot.map({ Date().timeIntervalSince($0.fetchedAt)>=300 || !$0.isCurrent(at:Date()) }) ?? true { refresh() }
    }
    func refresh() {
        guard configuration.enabled,!refreshing,!keychainBusy else { return }
        refreshing=true;status = .refreshing
        let token=generation
        performKeyOperation({ try $0.read() }) { [weak self] result in
            guard let self else { return }
            guard self.generation == token else {
                // A disable/re-enable while Security was blocked supersedes this read.
                self.refresh();return
            }
            switch result {
            case .failure:self.refreshing=false;self.status = .keychainUnavailable
            case .success(let key):
                guard let key,!key.isEmpty else {
                    self.refreshing=false;self.hasConfiguredKey=false;self.snapshot=nil
                    self.status = .configureKey;return
                }
                self.hasConfiguredKey=true;self.fetchUsage(key:key)
            }
        }
    }
    private func fetchUsage(key:String) {
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

// Own drafts outside the view tree so inactive panes can be released safely.
final class APISettingsDraft:ObservableObject {
    @Published var key=""
    @Published var project:String
    @Published var budget:String
    @Published var startDay:Int
    init(configuration:OpenAIUsageConfiguration) {
        project=configuration.projectID
        budget=configuration.manualBudget.map { String($0) } ?? ""
        startDay=configuration.cycleStartDay
    }
}

struct OpenAIUsageSettings:View {
    @ObservedObject var controller:OpenAIUsageController
    @ObservedObject var draft:APISettingsDraft
    var body:some View {
        Group {
          Section {
            Toggle(L10n.string("api.settings.show"),isOn:Binding(get:{controller.configuration.enabled},set:{controller.setEnabled($0)}))
                .help(L10n.string("api.settings.show.help"))
          }
            if controller.configuration.enabled {
              Section(L10n.string("api.settings.connection")) {
                SecureField(L10n.string("api.settings.key"),text:$draft.key,prompt:Text(L10n.string("api.settings.key.prompt")))
                    .help(L10n.string("api.settings.key.help"))
                TextField(L10n.string("api.settings.project"),text:$draft.project,prompt:Text(L10n.string("api.settings.project.prompt")))
                    .help(L10n.string("api.settings.project.help"))
                HStack {
                    Text(L10n.string("api.settings.status"));Spacer()
                    if controller.keychainBusy { ProgressView().controlSize(.small) }
                    Text(controller.status.text).foregroundStyle(.secondary)
                }
                    .fixedSize(horizontal:false,vertical:true)
              }
              Section(L10n.string("api.settings.cycle")) {
                Picker(L10n.string("api.settings.startDay"),selection:$draft.startDay) {
                    ForEach(1...31,id:\.self) { Text(L10n.format("api.settings.startDay.option",$0)).tag($0) }
                }.id("api-cycle-day."+L10n.language.code).help(L10n.string("api.settings.startDay.help"))
                HStack {
                    Text(L10n.string("api.settings.plan"));Spacer()
                    Text(controller.planTitle).foregroundStyle(.secondary)
                    Button { controller.refreshAccountPlan() } label: { Image(systemName:"arrow.clockwise") }
                        .buttonStyle(.borderless).disabled(controller.planRefreshing).help(L10n.string("api.settings.plan.refresh"))
                }
                TextField(L10n.string("api.settings.budget"),text:$draft.budget,prompt:Text(controller.automaticAmountPrompt))
                    .help(L10n.string("api.settings.budget.help"))
              }
              Section {
                HStack {
                    Button(L10n.string("api.settings.save")) {
                        let submittedKey=draft.key
                        controller.save(key:submittedKey,project:draft.project,budget:draft.budget,startDay:draft.startDay) { saved in
                            if saved && draft.key == submittedKey { draft.key="" }
                        }
                    }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    Button(L10n.string("api.settings.deleteKey")) { controller.removeKey();draft.key="" }
                }.disabled(controller.keychainBusy)
              }
            }
        }.onAppear {
            if controller.configuration.enabled { controller.refreshIfNeeded() }
        }
    }
}

struct OpenAIUsagePanel:View {
    @ObservedObject var controller:OpenAIUsageController
    let metric:DisplayMetric
    let now:Date
    let settings:()->Void
    var body:some View {
        if controller.configuration.enabled && controller.hasConfiguredKey {
            let projectID=controller.configuration.projectID
            QuotaSectionCard {
              VStack(alignment:.leading,spacing:16) {
                HStack(spacing:8) {
                    Text("OpenAI API").font(.system(size:15,weight:.bold)).fixedSize()
                    Spacer(minLength:0)
                    if !projectID.isEmpty {
                        Text(L10n.string("api.panel.project"))
                            .font(.system(size:10)).foregroundStyle(.secondary)
                    }
                    if controller.refreshing { ProgressView().controlSize(.small) }
                }.help(projectID.isEmpty ? L10n.string("api.panel.organization.help"):projectID)
                if let data=controller.snapshot,data.isCurrent(at:now) {
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
