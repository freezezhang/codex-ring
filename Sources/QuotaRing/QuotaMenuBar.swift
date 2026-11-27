import AppKit
import SwiftUI
import QuotaCore

private final class QuotaFloatingPanel:NSPanel {
    override var canBecomeKey:Bool { true }
    override var canBecomeMain:Bool { false }
}

private final class QuotaPanelClock:ObservableObject {
    @Published var now=Date()
}

final class QuotaMenuBar:NSObject {
    private enum Anchor {
        case menuBar, ring(NSView)
    }

    private let model:SettingsModel
    private var item:NSStatusItem?
    private var anchor:Anchor?
    private let panel=QuotaFloatingPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],
                                         backing:.buffered,defer:false)
    private let clock=QuotaPanelClock()
    private var clockTimer:Timer?
    private var hostingView:NSView?
    private var fitScheduled=false
    private var localMonitor:Any?,globalMonitor:Any?,deactivationObserver:NSObjectProtocol?
    // The CodexRing gauge and terminal prompt, in white for the menu bar.
    private let menuIcon = NSImage(size:NSSize(width:18,height:18),flipped:false) { _ in
        let track=NSBezierPath(ovalIn:NSRect(x:2,y:2,width:14,height:14))
        track.lineWidth=1.7
        NSColor.white.withAlphaComponent(0.45).setStroke()
        track.stroke()

        NSColor.white.setStroke()
        let gauge=NSBezierPath()
        gauge.lineWidth=track.lineWidth
        gauge.lineCapStyle = .round
        gauge.appendArc(withCenter:NSPoint(x:9,y:9),radius:7,startAngle:90,endAngle:-180,clockwise:true)
        gauge.stroke()

        let prompt=NSBezierPath()
        prompt.lineWidth=1.5
        prompt.lineCapStyle = .round
        prompt.lineJoinStyle = .round
        prompt.move(to:NSPoint(x:5.7,y:10.8))
        prompt.line(to:NSPoint(x:7.9,y:8.7))
        prompt.line(to:NSPoint(x:5.7,y:6.6))
        prompt.move(to:NSPoint(x:9.5,y:6.6))
        prompt.line(to:NSPoint(x:12.3,y:6.6))
        prompt.stroke()
        return true
    }
    var onRefresh:(()->Void)?,onSettings:(()->Void)?,onQuit:(()->Void)?,onRingClose:(()->Void)?
    var isShowingFromRing:Bool {
        if case .ring? = anchor { return true }
        return false
    }
    init(model:SettingsModel) {
        self.model=model
        super.init()
        panel.isReleasedWhenClosed=false;panel.isOpaque=false;panel.backgroundColor = .clear
        panel.hasShadow=true;panel.level = .popUpMenu;panel.animationBehavior = .none
        panel.collectionBehavior=[.moveToActiveSpace,.fullScreenAuxiliary,.ignoresCycle]
        deactivationObserver=NotificationCenter.default.addObserver(forName:NSApplication.didResignActiveNotification,object:nil,queue:.main) { [weak self] _ in self?.close() }
    }
    private func mountPanelContent() {
        let material=NSVisualEffectView(frame:.zero)
        material.material = .popover;material.blendingMode = .behindWindow;material.state = .active
        material.wantsLayer=true;material.layer?.cornerRadius=isShowingFromRing ? 12:16;material.layer?.masksToBounds=true
        let host=NSHostingView(rootView:QuotaMenuView(model:model,clock:clock,showsFullPanel:!isShowingFromRing,
            contentSizeChanged:{ [weak self] in self?.scheduleFit() },
            refresh:{ [weak self] in self?.onRefresh?() },
            settings:{ [weak self] in self?.close();self?.onSettings?() },
            quit:{ [weak self] in self?.close();self?.onQuit?() }))
        host.autoresizingMask=[.width,.height];material.addSubview(host)
        hostingView=host;panel.contentView=material
    }
    deinit {
        clockTimer?.invalidate()
        removeMonitors()
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
    }
    func update(enabled:Bool) {
        guard enabled else {
            if case .menuBar? = anchor { close() }
            if let item { NSStatusBar.system.removeStatusItem(item);self.item=nil }
            scheduleFit()
            return
        }
        if item == nil {
            let newItem=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
            newItem.button?.target=self;newItem.button?.action=#selector(togglePanel)
            newItem.button?.sendAction(on:.leftMouseUp)
            item=newItem
        }
        if let button=item?.button {
            let showQuota=model.preferences.showMenuBarQuota
            let title=showQuota ? " "+(model.menuPresentation?.title ?? "—") : ""
            let label=(showQuota ? model.menuPresentation?.help : nil) ?? "CodexRing"
            if button.title != title { button.title=title }
            button.font=NSFont.monospacedDigitSystemFont(ofSize:13,weight:.medium)
            button.image=menuIcon
            button.imagePosition=showQuota ? .imageLeft : .imageOnly
            button.toolTip=label
            button.setAccessibilityLabel(label)
        }
        scheduleFit()
    }
    func close() {
        guard hostingView != nil else { return }
        let wasFromRing=isShowingFromRing
        anchor=nil
        clockTimer?.invalidate();clockTimer=nil
        removeMonitors()
        // An ordered-out NSWindow can still lay out its SwiftUI view tree.
        hostingView=nil
        panel.orderOut(nil);panel.contentView=nil
        if wasFromRing { onRingClose?() }
    }
    func closeRingPanel() {
        if isShowingFromRing { close() }
    }
    func toggleFromRing(_ view:NSView) {
        if isShowingFromRing { close();return }
        show(at:.ring(view))
    }
    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor);self.localMonitor=nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor);self.globalMonitor=nil }
    }
    private func scheduleFit() {
        guard panel.isVisible,!fitScheduled else { return }
        fitScheduled=true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fitScheduled=false
            if self.panel.isVisible { self.fitPanel() }
        }
    }
    private func fitPanel() {
        guard let view=hostingView,let anchor else { return }
        guard let source=sourceView(for:anchor),let window=source.window else { close();return }
        view.layoutSubtreeIfNeeded()
        let size=view.fittingSize
        guard size.width>0,size.height>0 else { return }
        let sourceFrame=window.convertToScreen(source.convert(source.bounds,to:nil))
        let screen=window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? sourceFrame
        let origin:CGPoint
        switch anchor {
        case .menuBar:
            origin=CGPoint(x:sourceFrame.midX-size.width/2,y:min(sourceFrame.minY-6,screen.maxY-6)-size.height)
        case .ring:
            let gap:CGFloat=8
            let right=sourceFrame.maxX+gap
            let left=sourceFrame.minX-gap-size.width
            if right+size.width<=screen.maxX-gap {
                origin=CGPoint(x:right,y:sourceFrame.midY-size.height/2)
            } else if left>=screen.minX+gap {
                origin=CGPoint(x:left,y:sourceFrame.midY-size.height/2)
            } else {
                let below=sourceFrame.minY-gap-size.height
                let above=sourceFrame.maxY+gap
                let preferredY=below>=screen.minY+gap || sourceFrame.midY>=screen.midY ? below:above
                origin=CGPoint(x:sourceFrame.midX-size.width/2,y:preferredY)
            }
        }
        let x=max(screen.minX+8,min(origin.x,screen.maxX-size.width-8))
        let y=max(screen.minY+8,min(origin.y,screen.maxY-size.height-8))
        let frame=NSRect(x:x,y:y,width:size.width,height:size.height).integral
        if panel.frame != frame { panel.setFrame(frame,display:true);panel.invalidateShadow() }
    }
    func show() {
        guard hostingView == nil else { return }
        show(at:.menuBar)
    }
    private func sourceView(for anchor:Anchor)->NSView? {
        switch anchor {
        case .menuBar:return item?.button
        case .ring(let view):
            guard let window=view.window,window.isVisible,window.isOnActiveSpace,
                  !view.isHiddenOrHasHiddenAncestor else { return nil }
            return view
        }
    }
    private func show(at anchor:Anchor) {
        guard sourceView(for:anchor)?.window != nil else { return }
        close()
        self.anchor=anchor
        clock.now=Date()
        mountPanelContent()
        fitPanel()
        guard hostingView != nil else { return }
        if case .menuBar = anchor { NSApp.activate(ignoringOtherApps:true) }
        panel.title=L10n.string("panel.windowTitle")
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)
        scheduleFit()
        let timer=Timer(timeInterval:1,repeats:true) { [weak self] _ in self?.clock.now=Date() }
        timer.tolerance=0.1
        clockTimer=timer;RunLoop.main.add(timer,forMode:.common)
        if !isShowingFromRing { model.apiUsage.refreshIfNeeded() }
        localMonitor=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.otherMouseDown,.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.close();return nil }
            } else if event.window !== self.panel {
                // Keep the current anchor alive until its mouse-up toggles the panel.
                if event.type == .leftMouseDown,!event.modifierFlags.contains(.control),
                   let anchor=self.anchor,let source=self.sourceView(for:anchor),
                   event.window === source.window,
                   source.bounds.contains(source.convert(event.locationInWindow,from:nil)) { return event }
                self.close()
            }
            return event
        }
        globalMonitor=NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.otherMouseDown]) { [weak self] _ in self?.close() }
    }
    @objc private func togglePanel() {
        if case .menuBar? = anchor { close();return }
        show(at:.menuBar)
    }
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
    @ObservedObject var clock:QuotaPanelClock
    @State private var contentHeight:CGFloat=440
    let showsFullPanel:Bool
    let contentSizeChanged:()->Void
    let refresh:()->Void,settings:()->Void,quit:()->Void
    var body:some View {
        VStack(spacing:0) {
            if showsFullPanel {
                QuotaSectionCard {
                    QuotaMenuHeader(model:model,account:model.apiUsage)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key:QuotaHeaderHeight.self,value:geometry.size.height)
                        })
                }.padding(.horizontal,12).padding(.top,12)
            }
            if let data=model.menuPresentation {
                quotaContent(data)
            }
            if showsFullPanel {
                Divider()
                actions
            }
        }.frame(width:showsFullPanel ? 320:260).fixedSize(horizontal:false,vertical:true)
            .overlay {
                if showsFullPanel {
                    RoundedRectangle(cornerRadius:16)
                        .strokeBorder(Color.primary.opacity(0.12),lineWidth:0.5)
                        .allowsHitTesting(false)
                }
            }
            .onPreferenceChange(QuotaHeaderHeight.self) { _ in contentSizeChanged() }
    }
    private var actions:some View {
        HStack(spacing:12) {
            Text("CodexRing").font(.system(size:15,weight:.medium)).foregroundStyle(.secondary)
            Spacer()
            Button {
                model.apiUsage.refreshAccountPlan();refresh()
            } label: {
                Image(systemName:"arrow.clockwise").frame(width:28,height:28)
            }.help(L10n.string("panel.refresh")).accessibilityLabel(L10n.string("panel.refresh")).disabled(model.isRefreshing)
            Button(action:settings) {
                Image(systemName:"gearshape").frame(width:28,height:28)
            }.help(L10n.string("common.settings")).accessibilityLabel(L10n.string("common.settings"))
            Button(action:quit) {
                Image(systemName:"power").frame(width:28,height:28)
            }.help(L10n.string("menu.quit")).accessibilityLabel(L10n.string("menu.quit"))
        }.buttonStyle(.borderless).font(.system(size:14,weight:.medium)).padding(.horizontal,20).padding(.vertical,10)
    }
    private func quotaContent(_ data:QuotaMenuPresentation)->some View {
        let now=clock.now
        return ScrollView {
            VStack(alignment:.leading,spacing:12) {
                QuotaSectionCard {
                    VStack(alignment:.leading,spacing:showsFullPanel ? 16:12) {
                        if showsFullPanel {
                            Text(L10n.string("panel.subscription")).font(.system(size:15,weight:.bold))
                        }
                        if let unavailable=data.unavailableRow {
                            let loading=unavailable.status == .loading || (model.isRefreshing && unavailable.status != .offline)
                            let symbol:String? = loading ? nil:(unavailable.status == .offline ? "wifi.slash":"info.circle")
                            QuotaPanelNotice(title:loading ? L10n.string("status.loading"):unavailable.statusText,
                                             symbol:symbol,lastRefreshedAt:data.lastRefreshedAt)
                        } else {
                            ForEach(data.rows) { row in
                                if row.used != nil {
                                    quota(row,at:now)
                                } else {
                                    HStack(alignment:.firstTextBaseline) {
                                        Text(row.title).font(.system(size:13,weight:.semibold))
                                        Spacer(minLength:8)
                                        Text(row.statusText).font(.system(size:12)).foregroundStyle(.secondary)
                                            .multilineTextAlignment(.trailing)
                                    }
                                }
                            }
                        }
                        if data.showsResetCards && data.metadataNotice == nil {
                            Divider()
                            cards(data,at:now)
                        }
                        if data.unavailableRow == nil,let notice=data.metadataNotice {
                            Text(notice).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if showsFullPanel {
                    OpenAIUsagePanel(controller:model.apiUsage,metric:model.preferences.metric,now:now,settings:settings)
                }
            }.padding(showsFullPanel ? 12:0)
                .fixedSize(horizontal:false,vertical:true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key:QuotaContentHeight.self,value:geometry.size.height)
                })
        }.frame(height:contentHeight)
            .onPreferenceChange(QuotaContentHeight.self) { height in
                let cappedHeight=min(440,ceil(height))
                guard cappedHeight>0,cappedHeight != contentHeight else { return }
                contentHeight=cappedHeight
                contentSizeChanged()
            }
    }
    private func cards(_ data:QuotaMenuPresentation,at now:Date)->some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text(L10n.string("panel.resetCards")).font(.system(size:12,weight:showsFullPanel ? .medium:.semibold))
                    .foregroundStyle(showsFullPanel ? Color.secondary:Color.primary)
                Spacer()
                Text(data.cardsSummary).font(.system(size:11)).foregroundStyle(.secondary)
            }
            VStack(alignment:.leading,spacing:showsFullPanel ? 8:5) {
                ForEach(data.cardRows.indices,id:\.self) { index in
                    cardLine(data.cardRows[index],at:now)
                }
            }.padding(.leading,showsFullPanel ? 16:4)
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
        }.help(L10n.format("panel.card.help",row.text))
            .accessibilityElement(children:.ignore).accessibilityLabel(L10n.format("panel.card.a11y",text))
    }
    private func quota(_ row:QuotaMenuRow,at now:Date)->some View {
        let pace=row.pace(at:now)
        let value=Text(row.title+" "+row.progressText).font(.system(size:13,weight:.semibold))
            .monospacedDigit().lineLimit(1).fixedSize(horizontal:true,vertical:false)
        let reset=Text(row.resetDescription(at:now)).font(.system(size:11)).foregroundStyle(.secondary)
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
        return VStack(alignment:.leading,spacing:showsFullPanel ? 10:8) {
            if showsFullPanel {
                HStack(alignment:.firstTextBaseline,spacing:8) {
                    value
                    Spacer(minLength:0)
                    reset
                }
            } else {
                VStack(alignment:.leading,spacing:4) {
                    HStack(alignment:.firstTextBaseline,spacing:6) {
                        Text(row.title).font(.system(size:14,weight:.semibold))
                        Text(row.metric.shortTitle).font(.system(size:11)).foregroundStyle(.secondary)
                        Spacer(minLength:4)
                        Text(row.metric == .used ? row.usedText:row.remainingText)
                            .font(.system(size:24,weight:.semibold))
                            .monospacedDigit().lineLimit(1)
                    }.accessibilityElement(children:.combine)
                    reset
                }
            }
            QuotaProgressBar(row:row,pace:pace)
            if let pace {
                Text(pace.summary).font(.system(size:11)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal:false,vertical:true)
                    .help(pace.explanation)
                    .accessibilityLabel(L10n.format("panel.pace.a11y",pace.summary,pace.explanation))
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
                    Text(L10n.string("panel.account")).font(.system(size:15,weight:.bold))
                    if model.menuPresentation?.isDebug == true {
                        Text(L10n.string("debug.badge")).font(.caption).foregroundStyle(.orange)
                    }
                }.fixedSize(horizontal:true,vertical:false)
                Spacer(minLength:0)
                Text(account.accountEmail ?? (account.planRefreshing ? L10n.string("panel.account.loading"):L10n.string("panel.account.missing")))
                    .font(.system(size:15,weight:.medium)).lineLimit(1).truncationMode(.middle)
                    .help(account.accountEmail ?? L10n.string("panel.account.help"))
                    .accessibilityLabel(L10n.format("panel.account.a11y",account.accountEmail ?? L10n.string("common.notProvided")))
            }
            HStack(alignment:.lastTextBaseline,spacing:12) {
                if let data=model.menuPresentation,data.unavailableRow == nil {
                    Text(model.isRefreshing ? L10n.string("common.refreshing"):data.updatedText)
                        .font(.system(size:11)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength:0)
                Text(account.accountPlan?.title ?? L10n.string("panel.plan.missing"))
                    .font(.system(size:12,weight:.medium)).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel(L10n.format("panel.plan.a11y",account.accountPlan?.title ?? L10n.string("common.notProvided")))
            }
        }
    }
}

struct QuotaPanelNotice:View {
    let title:String
    let symbol:String?
    let lastRefreshedAt:Date?

    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(alignment:.firstTextBaseline,spacing:8) {
                if let symbol {
                    Image(systemName:symbol).foregroundStyle(.secondary).accessibilityHidden(true)
                } else {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                }
                Text(title).font(.system(size:13,weight:.medium)).fixedSize(horizontal:false,vertical:true)
            }
            if let lastRefreshedAt {
                Text(L10n.format("panel.lastSuccessfulRefresh",QuotaDateText.string(lastRefreshedAt)))
                    .font(.system(size:11)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

/// The subscription and API sections are peers; reset cards stay inside the subscription card.
struct QuotaSectionCard<Content:View>:View {
    @ViewBuilder var content:()->Content
    var body:some View {
        content().frame(maxWidth:.infinity,alignment:.leading).padding(12)
            .background(Color.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(Color.primary.opacity(0.07),lineWidth:0.5))
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
            .accessibilityLabel(quotaName)
            .accessibilityValue(row.used == nil ? row.statusText:pace.map { L10n.format("panel.bar.value",row.progressText,$0.summary) } ?? row.progressText)
            .help(markerHelp)
    }
    private var quotaName:String { L10n.format("panel.bar.a11y",row.title,row.metric.title) }
    private var markerHelp:String {
        var items:[String]=[]
        if !row.divisionMarkers.isEmpty { items.append(row.period == .week ? L10n.string("panel.ticks.week"):L10n.string("panel.ticks.fiveHours")) }
        if pace?.markerPercent != nil { items.append(L10n.string("panel.ticks.pace")) }
        return items.isEmpty ? quotaName:items.joined(separator:L10n.string("punctuation.listSeparator"))+L10n.string("punctuation.sentenceEnd")
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
