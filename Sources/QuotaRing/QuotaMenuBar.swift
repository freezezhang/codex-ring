import AppKit
import SwiftUI
import QuotaCore

private final class QuotaFloatingPanel:NSPanel {
    override var canBecomeKey:Bool { true }
    override var canBecomeMain:Bool { false }
}

final class QuotaMenuBar:NSObject {
    private let model:SettingsModel
    private var item:NSStatusItem?
    private let panel=QuotaFloatingPanel(contentRect:.zero,styleMask:[.borderless],backing:.buffered,defer:false)
    private var hostingView:NSView?
    private var localMonitor:Any?,globalMonitor:Any?,deactivationObserver:NSObjectProtocol?
    private let menuIcon:NSImage? = {
        let icon=Bundle.main.url(forResource:"ChatGPTMenuIcon",withExtension:"png").flatMap { NSImage(contentsOf:$0) }
        icon?.isTemplate=true;icon?.size=NSSize(width:18,height:18)
        return icon
    }()
    var onRefresh:(()->Void)?,onSettings:(()->Void)?,onQuit:(()->Void)?,onDisableOverlay:(()->Void)?
    init(model:SettingsModel) {
        self.model=model
        super.init()
        panel.isReleasedWhenClosed=false;panel.isOpaque=false;panel.backgroundColor = .clear
        panel.hasShadow=true;panel.level = .popUpMenu;panel.animationBehavior = .none
        panel.collectionBehavior=[.moveToActiveSpace,.fullScreenAuxiliary,.ignoresCycle]
        panel.appearance=NSAppearance(named:.darkAqua)
        let material=NSVisualEffectView(frame:.zero)
        material.material = .popover;material.blendingMode = .behindWindow;material.state = .active
        material.wantsLayer=true;material.layer?.cornerRadius=16;material.layer?.masksToBounds=true
        material.layer?.borderWidth=0.5;material.layer?.borderColor=NSColor.white.withAlphaComponent(0.12).cgColor
        let host=NSHostingView(rootView:QuotaMenuView(model:model,
            contentSizeChanged:{ [weak self] in
                DispatchQueue.main.async { [weak self] in self?.fitPanel() }
            },
            refresh:{ [weak self] in self?.onRefresh?() },
            settings:{ [weak self] in self?.close();self?.onSettings?() },
            quit:{ [weak self] in self?.close();self?.onQuit?() }))
        host.autoresizingMask=[.width,.height];material.addSubview(host)
        hostingView=host;panel.contentView=material
        deactivationObserver=NotificationCenter.default.addObserver(forName:NSApplication.didResignActiveNotification,object:nil,queue:.main) { [weak self] _ in self?.close() }
    }
    deinit {
        removeMonitors()
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
    }
    func update(enabled:Bool) {
        guard enabled else {
            close()
            if let item { NSStatusBar.system.removeStatusItem(item);self.item=nil }
            return
        }
        if item == nil {
            let newItem=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
            newItem.button?.target=self;newItem.button?.action=#selector(togglePanel)
            newItem.button?.sendAction(on:[.leftMouseUp,.rightMouseUp])
            item=newItem
        }
        let title=" "+(model.menuPresentation?.title ?? "—")
        if item?.button?.title != title { item?.button?.title=title }
        item?.button?.font=NSFont.monospacedDigitSystemFont(ofSize:13,weight:.medium)
        item?.button?.image=menuIcon;item?.button?.imagePosition = .imageLeft
        item?.button?.toolTip=model.menuPresentation?.help ?? "CodexRing"
        item?.button?.setAccessibilityLabel(model.menuPresentation?.help ?? "CodexRing")
        if panel.isVisible {
            DispatchQueue.main.async { [weak self] in self?.fitPanel() }
        }
    }
    func close() {
        panel.orderOut(nil);model.menuPanelVisible=false;removeMonitors()
    }
    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor);self.localMonitor=nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor);self.globalMonitor=nil }
    }
    private func fitPanel() {
        guard let view=hostingView,let button=item?.button,let window=button.window else { return }
        view.layoutSubtreeIfNeeded()
        let size=view.fittingSize
        guard size.width>0,size.height>0 else { return }
        let anchor=window.convertToScreen(button.convert(button.bounds,to:nil))
        let screen=window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchor
        let x=max(screen.minX+8,min(anchor.midX-size.width/2,screen.maxX-size.width-8))
        let top=min(anchor.minY-6,screen.maxY-6)
        let y=max(screen.minY+8,top-size.height)
        let frame=NSRect(x:x,y:y,width:size.width,height:size.height).integral
        if panel.frame != frame { panel.setFrame(frame,display:true);panel.invalidateShadow() }
    }
    func show() {
        guard item?.button != nil,!panel.isVisible else { return }
        fitPanel()
        NSApp.activate(ignoringOtherApps:true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)
        model.menuPanelVisible=true;model.apiUsage.refreshIfNeeded()
        localMonitor=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.otherMouseDown,.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.close();return nil }
            } else if event.window !== self.panel {
                // Let the status button's action toggle the panel. Closing on its
                // mouse-down would otherwise reopen it on the following mouse-up.
                if let button=self.item?.button,event.window === button.window,
                   button.bounds.contains(button.convert(event.locationInWindow,from:nil)) { return event }
                self.close()
            }
            return event
        }
        globalMonitor=NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.otherMouseDown]) { [weak self] _ in self?.close() }
    }
    @objc private func togglePanel() {
        guard let button=item?.button else { return }
        if let event=NSApp.currentEvent,event.type == .rightMouseUp {
            close()
            let menu=NSMenu()
            for (title,action) in [("刷新额度",#selector(refresh)),("设置…",#selector(settings))] {
                let entry=NSMenuItem(title:title,action:action,keyEquivalent:"");entry.target=self;menu.addItem(entry)
            }
            if model.preferences.overlayCodexUsage {
                let entry=NSMenuItem(title:"关闭覆盖 Codex 额度",action:#selector(disableOverlay),keyEquivalent:"");entry.target=self;menu.addItem(entry)
            }
            menu.addItem(.separator())
            let quit=NSMenuItem(title:"退出 CodexRing",action:#selector(quit),keyEquivalent:"");quit.target=self;menu.addItem(quit)
            NSMenu.popUpContextMenu(menu,with:event,for:button)
            return
        }
        if panel.isVisible { close();return }
        show()
    }
    @objc private func refresh() { onRefresh?() }
    @objc private func settings() { close();onSettings?() }
    @objc private func quit() { close();onQuit?() }
    @objc private func disableOverlay() { close();onDisableOverlay?() }
}

private struct QuotaContentHeight:PreferenceKey {
    static let defaultValue:CGFloat=0
    static func reduce(value:inout CGFloat,nextValue:()->CGFloat) { value=max(value,nextValue()) }
}

private struct QuotaHeaderHeight:PreferenceKey {
    static let defaultValue:CGFloat=0
    static func reduce(value:inout CGFloat,nextValue:()->CGFloat) { value=max(value,nextValue()) }
}

private struct QuotaMenuView:View {
    @ObservedObject var model:SettingsModel
    @State private var contentHeight:CGFloat=440
    let contentSizeChanged:()->Void
    let refresh:()->Void,settings:()->Void,quit:()->Void
    var body:some View {
        VStack(spacing:0) {
            QuotaSectionCard {
                QuotaMenuHeader(model:model,account:model.apiUsage)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key:QuotaHeaderHeight.self,value:geometry.size.height)
                    })
            }.padding(.horizontal,12).padding(.top,12)
            if let data=model.menuPresentation {
                quotaContent(data)
            }
            Divider()
            HStack(spacing:12) {
                Text("CodexRing").font(.system(size:15,weight:.medium)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.apiUsage.refreshAccountPlan();refresh()
                } label: {
                    Image(systemName:"arrow.clockwise").frame(width:28,height:28)
                }.help("刷新额度与账号").accessibilityLabel("刷新额度与账号").disabled(model.isRefreshing)
                Button(action:settings) {
                    Image(systemName:"gearshape").frame(width:28,height:28)
                }.help("设置").accessibilityLabel("设置")
                Button(action:quit) {
                    Image(systemName:"power").frame(width:28,height:28)
                }.help("退出 CodexRing").accessibilityLabel("退出 CodexRing")
            }.buttonStyle(.borderless).font(.system(size:14,weight:.medium)).padding(.horizontal,20).padding(.vertical,10)
        }.frame(width:320).fixedSize(horizontal:false,vertical:true)
            .preferredColorScheme(.dark)
            .onPreferenceChange(QuotaHeaderHeight.self) { _ in contentSizeChanged() }
    }
    private func quotaContent(_ data:QuotaMenuPresentation)->some View {
        return ScrollView {
            VStack(alignment:.leading,spacing:12) {
                QuotaSectionCard {
                    VStack(alignment:.leading,spacing:16) {
                        Text("OpenAI 订阅").font(.system(size:15,weight:.bold))
                        ForEach(data.rows) { row in quota(row) }
                        if data.showsResetCards {
                            Divider().overlay(Color.white.opacity(0.03))
                            cards(data)
                        }
                        if let notice=data.metadataNotice {
                            Text(notice).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                OpenAIUsagePanel(controller:model.apiUsage,metric:model.preferences.metric,settings:settings)
            }.padding(12)
                .fixedSize(horizontal:false,vertical:true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key:QuotaContentHeight.self,value:geometry.size.height)
                })
        }.frame(height:min(440,contentHeight))
            .onPreferenceChange(QuotaContentHeight.self) { height in
                guard height>0,abs(contentHeight-height)>0.5 else { return }
                contentHeight=height
                contentSizeChanged()
            }
    }
    @ViewBuilder private func cards(_ data:QuotaMenuPresentation)->some View {
        if model.menuPanelVisible {
            TimelineView(.periodic(from:.now,by:1)) { context in
                cards(data,at:context.date)
            }
        } else {
            cards(data,at:Date())
        }
    }
    private func cards(_ data:QuotaMenuPresentation,at now:Date)->some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text("重置卡").font(.system(size:12,weight:.medium)).foregroundStyle(.secondary)
                Spacer()
                Text(data.cardsSummary).font(.system(size:11)).foregroundStyle(.secondary)
            }
            VStack(alignment:.leading,spacing:8) {
                ForEach(data.cardRows.indices,id:\.self) { index in
                    cardLine(data.cardRows[index],at:now)
                }
            }.padding(.leading,16)
        }
    }
    private func cardLine(_ row:QuotaMenuCardRow,at now:Date)->some View {
        let text=row.displayText(at:now)
        let color:Color? = {
            switch row.expiryBand(at:now) {
            case .normal:return nil
            case .yellow:return .yellow
            case .orange:return .orange
            case .red:return .red
            }
        }()
        return HStack(alignment:.firstTextBaseline,spacing:12) {
            Image(systemName:"clock").foregroundStyle(color ?? .secondary)
            Text(text).font(.system(size:12)).monospacedDigit().foregroundStyle(color ?? .secondary)
            Spacer(minLength:0)
        }.help("到期时间："+row.text)
            .accessibilityElement(children:.ignore).accessibilityLabel("重置卡："+text)
    }
    @ViewBuilder private func quota(_ row:QuotaMenuRow)->some View {
        if model.menuPanelVisible && (row.panel.showPace || row.panel.resetStyle == .countdown) {
            TimelineView(.periodic(from:.now,by:1)) { context in
                quota(row,at:context.date)
            }
        } else {
            quota(row,at:Date())
        }
    }
    private func quota(_ row:QuotaMenuRow,at now:Date)->some View {
        let pace=row.pace(at:now)
        return VStack(alignment:.leading,spacing:10) {
            HStack(alignment:.firstTextBaseline,spacing:8) {
                Text(row.title+" "+row.progressText).font(.system(size:13,weight:.semibold))
                    .monospacedDigit().lineLimit(1).fixedSize(horizontal:true,vertical:false)
                Spacer(minLength:0)
                Text(row.resetDescription(at:now)).font(.system(size:11)).foregroundStyle(.secondary)
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
            }
            QuotaProgressBar(row:row,pace:pace)
            if row.used == nil {
                Text(row.statusText).font(.system(size:11)).foregroundStyle(.secondary)
            }
            if let pace {
                Text(pace.summary).font(.system(size:11)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal:false,vertical:true)
                    .help(pace.explanation)
                    .accessibilityLabel(pace.summary+"。"+pace.explanation)
            }
        }
    }
}

private struct QuotaMenuHeader:View {
    @ObservedObject var model:SettingsModel
    @ObservedObject var account:OpenAIUsageController
    var body:some View {
        VStack(spacing:8) {
            HStack(alignment:.lastTextBaseline,spacing:12) {
                HStack(alignment:.lastTextBaseline,spacing:6) {
                    Text("账号").font(.system(size:15,weight:.bold))
                    if model.menuPresentation?.isDebug == true {
                        Text("调试").font(.caption).foregroundStyle(.orange)
                    }
                }.fixedSize(horizontal:true,vertical:false)
                Spacer(minLength:0)
                Text(account.accountEmail ?? (account.planRefreshing ? "正在读取账号…":"账号未提供"))
                    .font(.system(size:15,weight:.medium)).lineLimit(1).truncationMode(.middle)
                    .help(account.accountEmail ?? "读取当前 Codex 登录账号")
                    .accessibilityLabel("用户账号："+(account.accountEmail ?? "未提供"))
            }
            HStack(alignment:.lastTextBaseline,spacing:12) {
                Text(model.isRefreshing ? "正在刷新…":model.menuPresentation?.updatedText ?? "尚未刷新")
                    .font(.system(size:11)).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength:0)
                Text(account.accountPlan?.title ?? "订阅类型未提供")
                    .font(.system(size:12,weight:.medium)).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel("订阅类型："+(account.accountPlan?.title ?? "未提供"))
            }
        }
    }
}

/// The subscription and API sections are peers; reset cards stay inside the subscription card.
struct QuotaSectionCard<Content:View>:View {
    @ViewBuilder var content:()->Content
    var body:some View {
        content().frame(maxWidth:.infinity,alignment:.leading).padding(12)
            .background(Color.white.opacity(0.045),in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(Color.white.opacity(0.07),lineWidth:0.5))
    }
}

struct QuotaProgressBar:View {
    let row:QuotaMenuRow
    let pace:QuotaPace?
    var body:some View {
        GeometryReader { geometry in
            ZStack(alignment:.leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                if let value=row.progressPercent {
                    Capsule().fill(barColor(row.band))
                        .frame(width:geometry.size.width*CGFloat(min(100,max(0,value)))/100)
                    ForEach(row.divisionMarkers,id:\.self) { percent in
                        Rectangle().fill(Color.primary.opacity(row.panel.tickStyle == .highContrast ? 0.9:0.4))
                            .frame(width:row.panel.tickStyle == .highContrast ? 2:1)
                            .offset(x:geometry.size.width*percent/100-(row.panel.tickStyle == .highContrast ? 1:0.5))
                    }
                    if let pace,let expected=pace.markerPercent {
                        let percent=row.progressPosition(expected)
                        Rectangle().fill(Color.black.opacity(0.8)).frame(width:5)
                            .overlay(Rectangle().fill(pace.position == .ahead ? Color.red:Color.green).frame(width:2))
                            .offset(x:max(0,min(geometry.size.width-5,geometry.size.width*percent/100-2.5)))
                    }
                }
            }.clipShape(Capsule())
        }.frame(height:7).accessibilityElement(children:.ignore)
            .accessibilityLabel(row.title+row.metric.shortTitle+"额度")
            .accessibilityValue(row.used == nil ? row.statusText:row.progressText+(pace.map { "，"+$0.summary } ?? ""))
            .help(markerHelp)
    }
    private var markerHelp:String {
        var items:[String]=[]
        if !row.divisionMarkers.isEmpty { items.append(row.period == .week ? "细刻度按每周工作日划分":"细刻度为每小时进度") }
        if pace?.markerPercent != nil { items.append("红／绿标记为当前时间的均匀用量进度") }
        return items.isEmpty ? row.title+row.metric.shortTitle+"额度":items.joined(separator:"；")+"。"
    }
    private func barColor(_ band:UsageBand?)->Color {
        switch band {
        case .normal:return .blue
        case .yellow:return .yellow
        case .orange:return .orange
        case .red:return .red
        case nil:return .secondary
        }
    }
}
