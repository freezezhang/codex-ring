import AppKit
import SwiftUI
import QuotaCore

final class QuotaMenuBar:NSObject,NSPopoverDelegate {
    private let model:SettingsModel
    private var item:NSStatusItem?
    private let popover=NSPopover()
    private let menuIcon:NSImage? = {
        let icon=Bundle.main.url(forResource:"ChatGPTMenuIcon",withExtension:"png").flatMap { NSImage(contentsOf:$0) }
        icon?.isTemplate=true;icon?.size=NSSize(width:18,height:18)
        return icon
    }()
    var onRefresh:(()->Void)?,onSettings:(()->Void)?,onQuit:(()->Void)?,onDisableOverlay:(()->Void)?
    init(model:SettingsModel) {
        self.model=model
        super.init()
        popover.behavior = .transient;popover.animates=false
        popover.delegate=self
        popover.appearance=NSAppearance(named:.darkAqua)
        popover.contentViewController=NSHostingController(rootView:QuotaMenuView(model:model,
            contentSizeChanged:{ [weak self] in
                DispatchQueue.main.async { [weak self] in self?.fitPanel() }
            },
            refresh:{ [weak self] in self?.onRefresh?() },
            settings:{ [weak self] in self?.close();self?.onSettings?() },
            quit:{ [weak self] in self?.close();self?.onQuit?() }))
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
        if popover.isShown {
            DispatchQueue.main.async { [weak self] in self?.fitPanel() }
        }
    }
    func close() { popover.performClose(nil) }
    func popoverDidShow(_ notification:Notification) { model.menuPanelVisible=true }
    func popoverWillClose(_ notification:Notification) { model.menuPanelVisible=false }
    private func fitPanel() {
        guard let view=popover.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let size=view.fittingSize
        if size.width>0,size.height>0,popover.contentSize != size { popover.contentSize=size }
    }
    func show() {
        guard let button=item?.button,!popover.isShown else { return }
        fitPanel()
        NSApp.activate(ignoringOtherApps:true)
        popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY)
        popover.contentViewController?.view.window?.makeKey()
        // Keep keyboard navigation available, but don't preselect a footer
        // button when the panel was opened with the mouse.
        DispatchQueue.main.async { [weak self] in
            guard let self,self.popover.isShown else { return }
            self.popover.contentViewController?.view.window?.makeFirstResponder(nil)
        }
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
        if popover.isShown { close();return }
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

private struct QuotaMenuView:View {
    @ObservedObject var model:SettingsModel
    @State private var contentHeight:CGFloat=440
    let contentSizeChanged:()->Void
    let refresh:()->Void,settings:()->Void,quit:()->Void
    var body:some View {
        VStack(spacing:0) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:5) {
                    HStack(spacing:8) {
                        Text("CodexRing").font(.system(size:20,weight:.semibold))
                        if model.menuPresentation?.isDebug == true {
                            Text("调试").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Text(model.isRefreshing ? "正在刷新…":model.menuPresentation?.updatedText ?? "尚未刷新")
                        .font(.system(size:11)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button(action:refresh) {
                    Image(systemName:"arrow.clockwise").font(.system(size:14,weight:.medium))
                        .frame(width:28,height:28)
                }.buttonStyle(.borderless).help("刷新额度")
                    .accessibilityLabel("刷新额度")
                    .disabled(model.isRefreshing || model.debugState.isEnabled)
            }.padding(20)
            Divider()
            if let data=model.menuPresentation {
                quotaContent(data)
            }
            Divider()
            HStack {
                Button(action:settings) { Label("设置",systemImage:"gearshape") }
                Spacer()
                Button(action:quit) { Label("退出",systemImage:"power") }
            }.buttonStyle(.borderless).font(.system(size:12)).padding(.horizontal,20).padding(.vertical,14)
        }.frame(width:320).fixedSize(horizontal:false,vertical:true)
            .preferredColorScheme(.dark)
    }
    private func quotaContent(_ data:QuotaMenuPresentation)->some View {
        return ScrollView {
            VStack(alignment:.leading,spacing:20) {
                ForEach(data.rows) { row in quota(row) }
                if data.showsResetCards {
                    Divider()
                    cards(data)
                }
                if let notice=data.metadataNotice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
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
    private func cards(_ data:QuotaMenuPresentation)->some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text("重置卡").font(.system(size:14,weight:.semibold))
                Spacer()
                Text(data.cardsSummary).font(.system(size:12)).foregroundStyle(.secondary)
            }
            ForEach(data.cardRows.indices,id:\.self) { index in
                cardLine(data.cardRows[index])
            }
        }
    }
    private func cardLine(_ row:QuotaMenuCardRow)->some View {
        let color:Color? = {
            switch row.expiryBand {
            case .normal:return nil
            case .yellow:return .yellow
            case .orange:return .orange
            case .red:return .red
            }
        }()
        return HStack(alignment:.firstTextBaseline,spacing:8) {
            Image(systemName:"clock").foregroundStyle(color ?? .secondary)
            Text(row.text).font(.system(size:12)).monospacedDigit().foregroundStyle(color ?? .primary)
            Spacer(minLength:0)
        }.accessibilityElement(children:.ignore).accessibilityLabel("重置卡到期 "+row.text)
    }
    private func quota(_ row:QuotaMenuRow)->some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(alignment:.firstTextBaseline) {
                Text(row.title).font(.system(size:15,weight:.semibold))
                Spacer()
                Text("已用 "+row.usedText).font(.system(size:15,weight:.semibold)).monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment:.leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    if let value=row.used {
                        Capsule().fill(barColor(row.band))
                            .frame(width:geometry.size.width*CGFloat(min(100,max(0,value)))/100)
                    }
                }
            }.frame(height:7).accessibilityElement(children:.ignore)
                .accessibilityLabel(row.title+"已用额度")
                .accessibilityValue(row.used == nil ? row.statusText:row.usedText)
            HStack(alignment:.firstTextBaseline,spacing:8) {
                Text(row.used == nil ? row.statusText:"剩余 "+row.remainingText)
                Spacer(minLength:0)
                if model.menuPanelVisible {
                    TimelineView(.periodic(from:.now,by:1)) { context in
                        Text(row.resetCountdown(at:context.date)).monospacedDigit().fixedSize()
                    }
                } else {
                    Text(row.resetCountdown(at:Date())).monospacedDigit().fixedSize()
                }
            }.font(.system(size:11)).foregroundStyle(.secondary)
        }
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
