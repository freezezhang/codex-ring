import AppKit
import QuotaCore

final class RingApplication: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var ring: RingView!
    private var material: NSVisualEffectView!
    private let store = PreferencesStore()
    private var preferences = RingPreferences()
    private var settings: RingSettingsWindow?
    private var model: SettingsModel!
    private var snapshot = QuotaSnapshot(source: .official, fetchedAt: Date(), loading: true)
    private var source: QuotaSource = .official
    private var expandedFrame: NSRect?
    private var refreshTimer: Timer?, clockTimer: Timer?
    private var hideWork: DispatchWorkItem?
    private var dockEdge: DockEdge?
    private var dockScreen: NSRect?
    private var isTucked = false, isDragging = false, fetching = false
    private var generation = 0
    private var capabilities=QuotaCapabilities()
    private var fiveHourSupport:Bool? { capabilities.support(for:preferences.bucketID) }
    private let client = AppServerClient()
    private var circleSize: CGFloat { CGFloat(preferences.size.rawValue) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences = store.load()
        applyTheme()
        model = SettingsModel(preferences: preferences)
        model.onPreferences = { [weak self] in self?.applyPreferences($0) }
        model.onRestore = { [weak self] in self?.restore() }
        model.onDiagnostics = { [weak self] in self?.redraw() }
        let fallback = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let position = preferences.position.map { NSPoint(x: $0.x, y: $0.y) }
        let screen = position.flatMap { p in NSScreen.screens.first(where: { $0.frame.contains(p) })?.visibleFrame } ?? fallback
        let initial = NSRect(x: position?.x ?? screen.maxX - circleSize - 24,
                             y: position?.y ?? screen.maxY - circleSize - 40, width: circleSize, height: circleSize)
        panel = NSPanel(contentRect: Docking.clamped(initial, to: screen), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        let container = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        container.wantsLayer = true; container.layer?.masksToBounds = true
        material = NSVisualEffectView(frame: container.bounds)
        material.material = .hudWindow; material.blendingMode = .behindWindow; material.state = .active
        material.wantsLayer = true; material.layer?.cornerRadius = circleSize / 2; material.layer?.masksToBounds = true
        ring = RingView(frame: material.bounds)
        ring.onDragStart = { [weak self] in self?.startDrag() }
        ring.onDragEnd = { [weak self] in self?.finishDrag() }
        ring.onEnter = { [weak self] in self?.reveal() }
        ring.onExit = { [weak self] in self?.scheduleHide() }
        ring.onClick = { [weak self] in self?.openSettings() }
        ring.onMenu = { [weak self] in self?.showMenu() }
        material.addSubview(ring); container.addSubview(material); panel.contentView = container
        panel.orderFrontRegardless(); redraw()
        configureRefreshTimer()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.redraw() }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(statusChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(statusChanged), name: NSWindow.didChangeOcclusionStateNotification, object: panel)
        refresh()
    }
    func applicationWillTerminate(_ notification: Notification) {
        savePosition(); refreshTimer?.invalidate(); clockTimer?.invalidate(); hideWork?.cancel(); client.cancel()
    }
    private var screenFrame: NSRect {
        NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: panel.frame.midX, y: panel.frame.midY)) })?.visibleFrame
        ?? panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
    }
    private func dateText(_ date: Date?) -> String {
        QuotaDateText.string(date)
    }
    @objc private func statusChanged() { if panel != nil { redraw() } }
    private func redraw() {
        guard ring != nil else { return }
        let composition=RingComposition(snapshot:snapshot,preferences:preferences,fiveHourSupport:fiveHourSupport)
        let d=composition.outer.display,presentation=composition.outer
        ring.composition=composition
        ring.positionLocked = preferences.positionLocked
        let sourceText = source == .official ? "官方 App Server 查询" : "查询已暂停"
        let used = d.remaining.map { String(format: "%.1f%%", 100 - $0) } ?? "未知"
        var accessibilityHelp = "\(sourceText)\n\(preferences.metric.title)：\(presentation.text)\n实际已用：\(used) · \(presentation.band?.accessibleName ?? "额度未知")\n重置：\(dateText(d.quota?.resetsAt))\n查询：\(dateText(d.fetchedAt))\n状态：\(d.subtitle)\n拖动移动，贴边隐藏，移入边缘恢复；点击打开设置。"
        if preferences.positionLocked { accessibilityHelp += "\n位置已固定，右键菜单取消固定可解锁。" }
        if let inner=composition.inner { accessibilityHelp += "\n5小时：\(inner.text)；重置：\(dateText(inner.display.quota?.resetsAt))；\(inner.display.subtitle)。中心数字仅表示1周额度。" }
        let top = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
        let diagnostics = "自身窗口：\(NSStringFromRect(panel.frame))\n全局中心点（左上原点）：\(Int(panel.frame.midX)),\(Int(top - panel.frame.midY))\n当前空间：\(panel.isOnActiveSpace)，可见：\(panel.isVisible)，未被遮挡：\(panel.occlusionState.contains(.visible))，已收起：\(isTucked)"
        if model.diagnostics { accessibilityHelp += "\n" + diagnostics }
        ring.toolTip = nil
        ring.setAccessibilityHelp(accessibilityHelp)
        panel.title = "CodexRing"
        model.snapshot = snapshot; model.source = source; model.isRefreshing = fetching
        model.fiveHourSupport=fiveHourSupport
        model.updatedText = dateText(d.fetchedAt)
        model.diagnosticText = diagnostics
    }
    private func applyPreferences(_ value: RingPreferences) {
        guard value != preferences else { return }
        let old = preferences; preferences = value
        if old.size != value.size {
            reveal(animated: false)
            let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            let frame = Docking.clamped(NSRect(x: center.x-circleSize/2,y:center.y-circleSize/2,width:circleSize,height:circleSize),to:screenFrame)
            panel.setFrame(frame, display: true); expandedFrame = frame
            material.frame = NSRect(origin: .zero, size: frame.size); material.layer?.cornerRadius = circleSize/2; ring.frame = material.bounds
        }
        if !value.autoHide { reveal(animated: false) }
        if old.refreshInterval != value.refreshInterval { configureRefreshTimer() }
        if old.theme != value.theme { applyTheme() }
        store.save(preferences); redraw()
    }
    private func applyTheme() {
        let appearance:NSAppearance?
        switch preferences.theme { case .system:appearance=nil;case .light:appearance=NSAppearance(named:.aqua);case .dark:appearance=NSAppearance(named:.darkAqua) }
        NSApp.appearance=appearance;panel?.appearance=appearance;settings?.window?.appearance=appearance
        ring?.needsDisplay=true
    }
    private func configureRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer=Timer.scheduledTimer(withTimeInterval:TimeInterval(preferences.refreshInterval.rawValue),repeats:true) { [weak self] _ in self?.refresh() }
    }
    private func savePosition() {
        guard panel != nil else { return }
        let frame = isTucked ? expandedFrame ?? panel.frame : panel.frame
        preferences.position = PanelPosition(x:frame.origin.x,y:frame.origin.y)
        if model != nil { model.preferences = preferences }; store.save(preferences)
    }
    private func startDrag() { isDragging = true; hideWork?.cancel(); reveal(animated: false) }
    private func finishDrag() {
        isDragging = false
        let screen = screenFrame, frame = Docking.clamped(panel.frame,to:screenFrame)
        dockEdge = Docking.nearestEdge(frame,screen:screen); dockScreen = dockEdge == nil ? nil:screen
        panel.setFrame(frame,display:true); expandedFrame = frame; savePosition(); redraw()
        if dockEdge != nil { scheduleHide(force:true) }
    }
    private func reveal(animated:Bool = true) {
        hideWork?.cancel()
        guard isTucked, let edge=dockEdge, let screen=dockScreen else { return }
        isTucked=false; move(to:Docking.revealed(expandedFrame ?? panel.frame,edge:edge,screen:screen),animated:animated)
    }
    private func move(to target:NSRect,animated:Bool) {
        var origin=NSPoint.zero
        let handle = Docking.handle(for: circleSize)
        if isTucked {
            if dockEdge == .left { origin.x = -(circleSize-handle) }
            if dockEdge == .bottom { origin.y = -(circleSize-handle) }
        }
        if animated && preferences.animations && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in context.duration=0.16; panel.animator().setFrame(target,display:true); material.animator().setFrameOrigin(origin) }
        } else { panel.setFrame(target,display:true); material.setFrameOrigin(origin) }
    }
    private func scheduleHide(force:Bool = false) {
        hideWork?.cancel()
        guard preferences.autoHide,!isDragging,!isTucked,dockEdge != nil,settings?.window?.isVisible != true else { return }
        let work=DispatchWorkItem { [weak self] in
            guard let self, let edge=self.dockEdge,let screen=self.dockScreen else { return }
            if !force && self.panel.frame.contains(NSEvent.mouseLocation) { return }
            self.expandedFrame=self.panel.frame; self.isTucked=true
            self.move(to:Docking.hidden(self.panel.frame,edge:edge,screen:screen),animated:true)
        }
        hideWork=work; DispatchQueue.main.asyncAfter(deadline:.now()+0.85,execute:work)
    }
    @objc private func screenChanged() { restore() }
    private func restore() {
        hideWork?.cancel(); reveal(animated:false); dockEdge=nil; dockScreen=nil; isTucked=false
        panel.setFrame(Docking.clamped(panel.frame,to:screenFrame),display:true); panel.orderFrontRegardless(); savePosition(); redraw()
    }
    private func refresh() {
        guard source == .official,!fetching else { redraw();return }
        fetching=true; redraw(); let request=generation
        DispatchQueue.global(qos:.utility).async { [weak self] in
            guard let self else { return }; let result=self.client.fetch()
            DispatchQueue.main.async { [weak self] in
                guard let self,self.generation == request,self.source == .official else { return }
                self.fetching=false;self.snapshot=result
                self.capabilities.observe(result)
                self.redraw()
            }
        }
    }
    private func connectLive() {
        generation += 1;client.cancel();source = .official;fetching=false
        snapshot=QuotaSnapshot(source:.official,fetchedAt:Date(),loading:true);refresh()
    }
    private func disconnect() {
        generation += 1;source = .disconnected;fetching=false;client.cancel()
        snapshot=QuotaSnapshot(source:.disconnected,fetchedAt:Date(),failure:.unavailable);redraw()
    }
    @objc private func openSettings() {
        hideWork?.cancel();reveal(animated:false)
        if settings == nil { settings=RingSettingsWindow(model:model,onClose:{ [weak self] in self?.scheduleHide() }) }
        redraw();settings?.showWindow(nil);NSApp.activate(ignoringOtherApps:true);settings?.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func refreshFromMenu() { source == .official ? refresh():connectLive() }
    @objc private func togglePositionLock() { var p=preferences;p.positionLocked.toggle();model.preferences=p }
    private func showMenu() {
        hideWork?.cancel();reveal(animated:false);let menu=NSMenu();menu.autoenablesItems=false
        for entry in RingMenuSpec.entries(for:preferences) {
            let item:NSMenuItem
            switch entry {
            case .refresh:item=NSMenuItem(title:"立即刷新",action:#selector(refreshFromMenu),keyEquivalent:"r");item.image=NSImage(systemSymbolName:"arrow.clockwise",accessibilityDescription:"刷新");item.isEnabled = !fetching
            case .settings:item=NSMenuItem(title:"设置…",action:#selector(openSettings),keyEquivalent:",")
            case .positionLock(let checked):item=NSMenuItem(title:"固定位置",action:#selector(togglePositionLock),keyEquivalent:"");item.state=checked ? .on:.off;item.image=NSImage(systemSymbolName:checked ? "pin.fill":"pin",accessibilityDescription:checked ? "已固定":"固定位置")
            case .quit:menu.addItem(.separator());item=NSMenuItem(title:"退出",action:#selector(quit),keyEquivalent:"q")
            }
            item.target=self;menu.addItem(item)
        }
        menu.popUp(positioning:nil,at:NSPoint(x:ring.bounds.midX,y:ring.bounds.midY),in:ring);scheduleHide()
    }
}
