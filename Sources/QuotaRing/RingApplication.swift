import AppKit
import ApplicationServices
import QuotaCore

final class RingApplication: NSObject, NSApplicationDelegate {
    private struct PanelLayout {
        var expandedFrame:NSRect?
        var edge:DockEdge?
        var screen:NSRect?
        var tucked=false
    }
    private var panel: NSPanel!
    private var desktopPanel:NSPanel!
    private var desktopAnchorEstablished=false
    private var fullscreenPanel:NSPanel?
    private var codexPanel:NSPanel?
    private let codexMonitor:CodexWindowMonitor
    private var codexAction:CodexFollowAction = .free
    private var codexTarget:CodexFollowWindow?
    private var overlayAccessibilityGranted=false
    private var overlayControlMissing=false
    private var overlayNoticeWork:DispatchWorkItem?
    private var overlayNoticeWindow:UInt32?
    private var overlayNoticeShown=false
    private var overlayNoticeGeneration=0
    private let onOverlayUnavailable:(()->Void)?
    private var overlayMissingMessage:String { L10n.string("overlay.controlMissing") }
    private let signingFingerprint=SigningFingerprint.current()
    private var quotaMenuBar:QuotaMenuBar?
    private var activeContextMenu:NSMenu?
    private var overlayActive:Bool { preferences.overlayCodexUsage && overlayAccessibilityGranted }
    private var trackingCodex:Bool { preferences.followCodex || overlayActive }
    private var hidesWithoutCodexWindow:Bool { trackingCodex && preferences.hideRingWithoutCodex }
    private var ringIsHidden:Bool {
        if preferences.ringHidden { return true }
        guard hidesWithoutCodexWindow else { return false }
        if case .attach = codexAction { return false }
        return true
    }
    private var followingCodex:Bool { panel != nil && panel === codexPanel }
    private var desktopLayout=PanelLayout(),fullscreenLayout=PanelLayout()
    private var spacePresentation=RingSpacePresentation()
    private var presentationObservation:NSKeyValueObservation?
    private var spaceRevision=0
    private var spaceChangedAt=Date.distantPast
    private var fullscreenScreen:NSScreen?
    private enum FullscreenEvidence {
        case none,windowCoversScreen,systemFlag
        var text:String {
            switch self {
            case .none:return L10n.string("diagnostics.evidence.none")
            case .windowCoversScreen:return L10n.string("diagnostics.evidence.window")
            case .systemFlag:return L10n.string("diagnostics.evidence.systemFlag")
            }
        }
    }
    private var fullscreenEvidence=FullscreenEvidence.none
    private var lastSpaceDiagnostic=""
    private var showingFullscreen:Bool { panel != nil && panel === fullscreenPanel }
    // Only the temporary fullscreen surface joins Spaces. The desktop anchor
    // remains managed and bound to its original Space.
    private var fullscreenBehavior:NSWindow.CollectionBehavior { [.canJoinAllSpaces,.fullScreenAuxiliary,.canJoinAllApplications,.ignoresCycle] }
    private var ring: RingView!
    private var material: NSVisualEffectView!
    private let store:PreferencesStore
    private let automaticRefresh:Bool
    private var preferences = RingPreferences()
    private var settings: RingSettingsWindow?
    private var debugWindow:RingDebugWindow?
    private var aboutWindow:RingAboutWindow?
    private var debugState=QuotaDebugState()
    private var debugFallbackFiveHourReset:Date?
    private var lastRefreshedAt:Date?
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
    private var fiveHourSupport:Bool? { debugState.isEnabled ? true:capabilities.support(for:preferences.bucketID) }
    private var displaySnapshot:QuotaSnapshot {
        debugState.snapshot(live:snapshot,selectedID:preferences.bucketID,fallbackFiveHourReset:debugFallbackFiveHourReset)
    }
    private var details:QuotaDetailsPresentation {
        QuotaDetailsPresentation(snapshot:displaySnapshot,metadataSnapshot:snapshot,preferences:preferences,
                                 fiveHourSupport:fiveHourSupport,lastRefreshedAt:lastRefreshedAt)
    }
    private let client = AppServerClient()
    private let notifications=QuotaNotificationController()
    private let confetti=ResetConfetti()
    private var coveringUsage:Bool { overlayActive && !overlayControlMissing }
    private var circleSize: CGFloat { coveringUsage ? 26:CGFloat(preferences.size.rawValue) }

    init(store:PreferencesStore = PreferencesStore(),codexMonitor:CodexWindowMonitor = CodexWindowMonitor(),automaticRefresh:Bool = true,onOverlayUnavailable:(()->Void)? = nil) {
        self.store=store;self.codexMonitor=codexMonitor;self.automaticRefresh=automaticRefresh
        self.onOverlayUnavailable=onOverlayUnavailable;super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences = store.load()
        L10n.apply(languageCode:preferences.languageCode)
        overlayAccessibilityGranted=AXIsProcessTrusted()
        if preferences.overlayCodexUsage && !overlayAccessibilityGranted {
            preferences.reconcileOverlayPermission(granted:false)
            store.save(preferences)
        }
        applyTheme()
        model = SettingsModel(preferences: preferences)
        model.onPreferences = { [weak self] in self?.applyPreferences($0) }
        model.onDiagnostics = { [weak self] in self?.redraw() }
        model.onDebugState = { [weak self] in self?.applyDebugState($0) }
        model.onOpenAccessibilitySettings = { [weak self] in self?.openAccessibilitySettings() }
        model.onAbout = { [weak self] in self?.openAbout() }
        model.onOpenDebug = { [weak self] in self?.openDebug() }
        notifications.onStatus = { [weak self] in self?.model.update(\.notificationStatus,$0) }
        notifications.onCelebrate = { [weak self] in self?.confetti.play() }
        notifications.refreshStatus()
        model.onNotificationSettings = { [weak self] in self?.notifications.openSettings() }
        model.onPreviewConfetti = { [weak self] in self?.confetti.play() }
        model.launchAtLogin=LaunchAtLogin.enabled;model.loginStatus=LaunchAtLogin.statusText
        model.onLoginChange = { [weak self] enabled in
            let error=LaunchAtLogin.setEnabled(enabled)
            self?.model.loginError=error
            self?.model.launchAtLogin=LaunchAtLogin.enabled
            self?.model.loginStatus=LaunchAtLogin.statusText
        }
        model.onLoginSettings = { LaunchAtLogin.openSettings() }
        let fallback = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let position = preferences.position.map { NSPoint(x: $0.x, y: $0.y) }
        let screen = position.flatMap { p in NSScreen.screens.first(where: { $0.frame.contains(p) })?.visibleFrame } ?? fallback
        let normalSize=CGFloat(preferences.size.rawValue)
        let initial = NSRect(x: position?.x ?? screen.maxX - normalSize - 24,
                             y: position?.y ?? screen.maxY - normalSize - 40, width: normalSize, height: normalSize)
        panel = NSPanel(contentRect: Docking.clamped(initial, to: screen), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        desktopPanel=panel
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        // Belong to the desktop where the panel is opened and participate in its
        // native transitions. Position locking only affects dragging.
        panel.collectionBehavior = [.managed, .ignoresCycle, .fullScreenNone]
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
        ring.onClick = { [weak self] in self?.handleRingClick() }
        ring.onMenu = { [weak self] event in self?.showMenu(event:event) }
        ring.constrainDragOrigin = { [weak self] origin in
            guard let self,self.followingCodex,let area=self.codexArea else { return origin }
            return Docking.clamped(NSRect(origin:origin,size:self.panel.frame.size),to:area).origin
        }
        material.addSubview(ring); container.addSubview(material); panel.contentView = container
        let front=NSWorkspace.shared.frontmostApplication
        let anchorScreen=NSScreen.screens.first(where:{$0.frame.contains(NSPoint(x:panel.frame.midX,y:panel.frame.midY))})
        let startsInFullscreen=front.map { fullscreenDisplay(for:$0.processIdentifier) != nil } == true
            || NSApp.currentSystemPresentationOptions.contains(.fullScreen)
            || anchorScreen.map { fullscreenDisplay(for:nil,on:$0) != nil } == true
        desktopAnchorEstablished = !startsInFullscreen
        updateRingVisibility()
        if desktopAnchorEstablished && !overlayActive { panel.orderFrontRegardless() }
        redraw()
        if automaticRefresh { configureRefreshTimer() }
        // Also recover if an app changes its fullscreen geometry without a
        // presentation-options notification (notably native fullscreen).
        clockTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.settings?.window?.isVisible == true {
                self.updateAccessibilityTrust(AXIsProcessTrusted())
                self.notifications.refreshStatus()
                self.model.update(\.launchAtLogin,LaunchAtLogin.enabled)
                self.model.update(\.loginStatus,LaunchAtLogin.statusText)
            }
            self.synchronizeSpace()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(actualSpaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(statusChanged), name: NSWindow.didChangeOcclusionStateNotification, object: panel)
        presentationObservation=NSApp.observe(\.currentSystemPresentationOptions,options:[.new]) { [weak self] _,_ in
            DispatchQueue.main.async { self?.spaceChanged() }
        }
        codexMonitor.onChange = { [weak self] snapshot in
            guard let self,self.trackingCodex else { return }
            switch snapshot {
            case .unavailable:
                if !self.overlayActive { return }
                self.codexAction = .hidden
            case .waiting:self.codexAction = .hidden
            case .basicWindows(let windows,_):
                self.codexAction=CodexFollow.action(enabled:true,windows:windows)
            case .windows(let windows,_):
                self.codexAction=CodexFollow.action(enabled:true,windows:windows)
            }
            self.synchronizeSpace()
        }
        codexMonitor.onAccessibilityChange = { [weak self] trusted in
            self?.updateAccessibilityTrust(trusted)
        }
        codexMonitor.tracksUsageControl=preferences.overlayCodexUsage
        if preferences.followCodex || preferences.overlayCodexUsage { codexMonitor.start() }
        spaceChanged()
        if automaticRefresh { refresh() }
        if ProcessInfo.processInfo.arguments.contains("--show-quota-panel") {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { [weak self] in self?.quotaMenuBar?.show() }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        confetti.dismiss()
        cancelOverlayNotice()
        spaceRevision += 1;presentationObservation=nil
        codexMonitor.stop()
        savePosition(); refreshTimer?.invalidate(); clockTimer?.invalidate(); hideWork?.cancel(); client.cancel()
    }
    private func openAccessibilitySettings() {
        guard let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
    private func updateAccessibilityTrust(_ trusted:Bool) {
        let changed=overlayAccessibilityGranted != trusted
        overlayAccessibilityGranted=trusted
        if preferences.overlayCodexUsage && !trusted {
            var value=preferences;value.reconcileOverlayPermission(granted:false)
            applyPreferences(value)
            return
        }
        guard changed else { return }
        codexAction = overlayActive ? .hidden:.free
        resizeCircle();synchronizeSpace();redraw()
    }
    private var screenFrame: NSRect {
        NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: panel.frame.midX, y: panel.frame.midY)) })?.visibleFrame
        ?? panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
    }
    private func dateText(_ date: Date?) -> String {
        QuotaDateText.string(date)
    }
    @objc private func statusChanged() {
        if panel != nil {
            if !panel.isVisible || !panel.isOnActiveSpace || !panel.occlusionState.contains(.visible) { ring?.dismissHover() }
            redraw()
        }
    }
    @objc private func actualSpaceChanged() {
        activeContextMenu?.cancelTracking()
        activeContextMenu=nil
        spaceChanged()
    }
    @objc private func spaceChanged() {
        cancelOverlayNotice()
        // A context menu can change app activation. Keep its source panel in
        // place throughout tracking; an actual Space change still dismisses it.
        guard activeContextMenu == nil else { return }
        ring?.dismissHover()
        hideWork?.cancel()
        guard panel != nil else { return }
        if trackingCodex {
            // Never let the all-Spaces overlay flash over an unrelated desktop
            // while the next read-only window sample is still in flight.
            if followingCodex { isDragging=false;codexPanel?.orderOut(nil);codexAction = .hidden }
            codexMonitor.invalidate()
        }
        spaceRevision += 1;let revision=spaceRevision
        spaceChangedAt=Date()
        // The active app's presentation options may settle after the Space
        // notification. Recheck briefly without polling or changing other apps.
        for delay in [0.15,0.65,1.2,2.5] {
            DispatchQueue.main.asyncAfter(deadline:.now()+delay) { [weak self] in
                guard let self,self.spaceRevision == revision else { return }
                self.synchronizeSpace()
            }
        }
        redraw()
    }
    private func synchronizeSpace() {
        guard activeContextMenu == nil else { return }
        if trackingCodex {
            switch codexAction {
            case .attach(let target):showCodex(target);redraw();return
            case .hidden:
                cancelOverlayNotice()
                beginCodexFollow(frame:expandedFrame ?? panel.frame)
                codexPanel?.orderOut(nil);redraw();return
            case .free:
                cancelOverlayNotice()
                if overlayActive || hidesWithoutCodexWindow {
                    beginCodexFollow(frame:expandedFrame ?? panel.frame)
                    codexPanel?.orderOut(nil);redraw();return
                }
                break
            }
        }
        if followingCodex { endCodexFollow() }
        guard let front=NSWorkspace.shared.frontmostApplication else { return }
        let ownAppIsActive=front.processIdentifier == ProcessInfo.processInfo.processIdentifier
        let presentationIsFullscreen=NSApp.currentSystemPresentationOptions.contains(.fullScreen)
        if !ownAppIsActive {
            // currentSystemPresentationOptions can remain empty for another
            // app's native fullscreen window. Inspect only public window bounds
            // for the foreground PID; never capture images or read window titles.
            fullscreenScreen=fullscreenDisplay(for:front.processIdentifier)
            fullscreenEvidence=fullscreenScreen != nil ? .windowCoversScreen:(presentationIsFullscreen ? .systemFlag:.none)
            if fullscreenScreen == nil,presentationIsFullscreen {
                fullscreenScreen=NSScreen.screens.first(where:{$0.frame.contains(NSEvent.mouseLocation)}) ?? NSScreen.main
            }
        }
        let surface=spacePresentation.observe(systemIsFullscreen:fullscreenScreen != nil,
                                              ownAppIsActive:ownAppIsActive)
        if surface == .fullscreen {
            if !showingFullscreen { switchToFullscreenPanel() }
            let center=NSPoint(x:panel.frame.midX,y:panel.frame.midY)
            if !panel.isOnActiveSpace || !panel.isVisible || fullscreenScreen?.frame.contains(center) == false {
                moveFullscreenPanelToActiveSpace()
            }
        } else if showingFullscreen || !desktopAnchorEstablished {
            let anchorScreen=NSScreen.screens.first(where:{$0.frame.contains(NSPoint(x:desktopPanel.frame.midX,y:desktopPanel.frame.midY))})
            let anchorScreenIsFullscreen=anchorScreen.map { fullscreenDisplay(for:nil,on:$0) != nil } ?? false
            if !desktopAnchorEstablished && (Date().timeIntervalSince(spaceChangedAt)<1 || anchorScreenIsFullscreen) {
                // App activation precedes the end of the Space animation. A
                // first desktop anchor created now can land in the old Space.
                // With separate display Spaces, another monitor can still be
                // fullscreen even though the foreground app is on a desktop.
                fullscreenPanel?.orderOut(nil)
            } else { switchToDesktopPanel() }
        }
        redraw()
    }
    private var codexArea:NSRect? {
        guard let target=codexTarget else { return nil }
        let screen=NSScreen.screens.max { a,b in
            let x=a.frame.intersection(target.frame),y=b.frame.intersection(target.frame)
            return (x.isNull ? 0:x.width*x.height)<(y.isNull ? 0:y.width*y.height)
        }
        return CodexFollow.area(window:target.frame,screen:screen?.visibleFrame ?? target.frame)
    }
    private func beginCodexFollow(frame:NSRect) {
        guard !followingCodex else { return }
        hideWork?.cancel()
        if showingFullscreen { fullscreenLayout=panelLayout;fullscreenPanel?.orderOut(nil) }
        else { desktopLayout=panelLayout }
        if codexPanel == nil {
            let window=NSPanel(contentRect:frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            window.isOpaque=false;window.backgroundColor = .clear;window.hasShadow=false
            window.hidesOnDeactivate=false;window.isReleasedWhenClosed=false
            window.collectionBehavior=fullscreenBehavior;window.animationBehavior = .none
            window.acceptsMouseMovedEvents=true
            codexPanel=window
            NotificationCenter.default.addObserver(self,selector:#selector(statusChanged),name:NSWindow.didChangeOcclusionStateNotification,object:window)
        }
        codexPanel?.setFrame(frame,display:false)
        usePanel(codexPanel!,layout:PanelLayout(expandedFrame:frame))
    }
    private func showCodex(_ target:CodexFollowWindow) {
        codexTarget=target
        guard !isDragging,let area=codexArea else { return }
        let frame:NSRect
        if overlayActive,let control=target.usageFrame,
           let overlay=CodexFollow.usageOverlayFrame(control:control,window:target.frame) {
            overlayControlMissing=false;cancelOverlayNotice()
            frame=overlay
        } else {
            overlayControlMissing=overlayActive
            if overlayControlMissing { scheduleOverlayNotice(windowID:target.id) }
            frame=CodexFollow.frame(in:area,size:circleSize,anchor:preferences.codexAnchor)
        }
        beginCodexFollow(frame:frame)
        hideWork?.cancel();dockEdge=nil;dockScreen=nil;isTucked=false
        if panel.frame != frame { move(to:frame,animated:false) }
        material.frame=NSRect(origin:.zero,size:frame.size)
        material.layer?.cornerRadius=frame.width/2;ring.frame=material.bounds
        expandedFrame=frame
        let top=NSScreen.screens.first?.frame.maxY ?? 0
        let windowBounds=CGRect(x:target.frame.minX,y:top-target.frame.maxY,width:target.frame.width,height:target.frame.height)
        let fullscreen=NSScreen.screens.contains { screen in
            let display=CGRect(x:screen.frame.minX,y:top-screen.frame.maxY,width:screen.frame.width,height:screen.frame.height)
            return FullscreenDetection.coversDisplay(window:windowBounds,display:display,topInset:screen.safeAreaInsets.top)
        }
        panel.level=fullscreen ? .floating:.normal
        // Same normal level + relative ordering keeps the ring above Codex but
        // below apps covering Codex. Fullscreen uses the eligible floating level.
        panel.order(.above,relativeTo:Int(target.id))
    }
    private func cancelOverlayNotice() {
        overlayNoticeGeneration += 1
        overlayNoticeWork?.cancel();overlayNoticeWork=nil;overlayNoticeWindow=nil
    }
    private func scheduleOverlayNotice(windowID:UInt32) {
        guard !ringIsHidden,!overlayNoticeShown,overlayNoticeWindow != windowID else { return }
        cancelOverlayNotice();overlayNoticeWindow=windowID
        let generation=overlayNoticeGeneration
        let work=DispatchWorkItem { [weak self] in
            guard let self,self.overlayNoticeGeneration == generation else { return }
            self.cancelOverlayNotice()
            guard self.overlayActive,self.overlayControlMissing,self.activeContextMenu == nil,
                  case .attach(let target)=self.codexAction,target.id == windowID,
                  self.panel.isVisible,self.panel.isOnActiveSpace else { return }
            self.overlayNoticeShown=true
            self.redraw()
            // Explain once per enabling session while continuing to locate.
            if let notify=self.onOverlayUnavailable { notify() }
            else { self.openSettings() }
        }
        overlayNoticeWork=work
        DispatchQueue.main.asyncAfter(deadline:.now()+3,execute:work)
    }
    private func endCodexFollow() {
        codexPanel?.orderOut(nil);codexTarget=nil
        usePanel(desktopPanel,layout:desktopLayout)
        if desktopAnchorEstablished,desktopPanel.isOnActiveSpace { desktopPanel.orderFrontRegardless() }
    }
    private func fullscreenDisplay(for pid:pid_t?,on target:NSScreen? = nil)->NSScreen? {
        guard let windows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]],
              let primary=NSScreen.screens.first else { return nil }
        // AppKit's origin is at the primary display's bottom left; WindowServer's
        // is at its top left. Using maxY across all monitors breaks stacked setups.
        let top=primary.frame.maxY
        for info in windows {
            guard let owner=(info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  owner != ProcessInfo.processInfo.processIdentifier,pid == nil || owner == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let bounds=info[kCGWindowBounds as String] as? [String:Any],
                  let frame=CGRect(dictionaryRepresentation:bounds as CFDictionary) else { continue }
            for screen in target.map({[$0]}) ?? NSScreen.screens {
                let display=CGRect(x:screen.frame.minX,y:top-screen.frame.maxY,width:screen.frame.width,height:screen.frame.height)
                if FullscreenDetection.coversDisplay(window:frame,display:display,topInset:screen.safeAreaInsets.top) { return screen }
            }
        }
        return nil
    }
    private var panelLayout:PanelLayout { PanelLayout(expandedFrame:expandedFrame,edge:dockEdge,screen:dockScreen,tucked:isTucked) }
    private func usePanel(_ next:NSPanel,layout:PanelLayout) {
        hideWork?.cancel();isDragging=false
        let content=panel.contentView;panel.contentView=nil
        panel=next;panel.contentView=content
        updateRingVisibility()
        dockEdge=layout.edge;dockScreen=layout.screen;isTucked=layout.tucked
        let previous=layout.expandedFrame ?? panel.frame
        let expanded=Docking.clamped(NSRect(x:previous.midX-circleSize/2,y:previous.midY-circleSize/2,width:circleSize,height:circleSize),to:screenFrame)
        expandedFrame=expanded
        material.frame=NSRect(origin:.zero,size:expanded.size);material.layer?.cornerRadius=circleSize/2;ring.frame=material.bounds
        let target:NSRect
        if isTucked,let edge=dockEdge,let screen=dockScreen { target=Docking.hidden(expanded,edge:edge,screen:screen) }
        else { isTucked=false;target=expanded }
        move(to:target,animated:false)
        applyTheme()
    }
    private func switchToFullscreenPanel() {
        desktopLayout=panelLayout
        let oldFrame=fullscreenLayout.expandedFrame ?? expandedFrame ?? panel.frame
        let frame=fullscreenPlacement(oldFrame)
        if fullscreenPanel == nil {
            let window=NSPanel(contentRect:frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            window.isOpaque=false;window.backgroundColor = .clear;window.hasShadow=false
            window.level = .floating;window.hidesOnDeactivate=false;window.isReleasedWhenClosed=false
            window.collectionBehavior=fullscreenBehavior;window.animationBehavior = .none
            fullscreenPanel=window;fullscreenLayout=PanelLayout(expandedFrame:frame)
            NotificationCenter.default.addObserver(self,selector:#selector(statusChanged),name:NSWindow.didChangeOcclusionStateNotification,object:window)
        }
        if frame != oldFrame { fullscreenLayout=PanelLayout(expandedFrame:frame) }
        fullscreenPanel?.setFrame(frame,display:false)
        // Leave the empty, transparent desktop anchor ordered in its original
        // Space so returning from fullscreen never relocates it to another one.
        usePanel(fullscreenPanel!,layout:fullscreenLayout)
        moveFullscreenPanelToActiveSpace()
    }
    private func fullscreenPlacement(_ frame:NSRect)->NSRect {
        // Use the actual fullscreen window's display, even if the pointer has
        // moved elsewhere or fullscreen was entered with a keyboard shortcut.
        guard let target=fullscreenScreen else { return frame }
        let source=NSScreen.screens.first(where:{$0.frame.contains(NSPoint(x:frame.midX,y:frame.midY))})
        return Docking.relocated(frame,from:source?.visibleFrame ?? target.visibleFrame,to:target.visibleFrame)
    }
    private func moveFullscreenPanelToActiveSpace() {
        guard let window=fullscreenPanel,showingFullscreen else { return }
        let oldFrame=expandedFrame ?? window.frame,newFrame=fullscreenPlacement(oldFrame)
        if newFrame != oldFrame {
            hideWork?.cancel();dockEdge=nil;dockScreen=nil;isTucked=false;expandedFrame=newFrame
            move(to:newFrame,animated:false)
        }
        // moveToActiveSpace only affects activation; orderFrontRegardless on a
        // nonactivating panel does not reliably migrate it to a foreign Space.
        // This surface can join all Spaces, and is ordered out on desktop return.
        window.orderFrontRegardless()
    }
    private func switchToDesktopPanel() {
        if showingFullscreen { fullscreenLayout=panelLayout }
        fullscreenPanel?.orderOut(nil)
        fullscreenPanel?.collectionBehavior=fullscreenBehavior
        var oldAnchor:NSPanel?
        if !desktopAnchorEstablished {
            // A launch from fullscreen has no ordinary desktop anchor yet.
            // Create it on the first ordinary Space instead of binding an empty
            // window to the fullscreen Space where the app happened to launch.
            let previous=desktopPanel!
            let window=NSPanel(contentRect:previous.frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            window.isOpaque=false;window.backgroundColor = .clear;window.hasShadow=false
            window.level = .floating;window.hidesOnDeactivate=false;window.isReleasedWhenClosed=false
            window.collectionBehavior=[.managed,.ignoresCycle,.fullScreenNone];window.animationBehavior = .none
            desktopPanel=window;desktopAnchorEstablished=true
            oldAnchor=previous
            NotificationCenter.default.removeObserver(self,name:NSWindow.didChangeOcclusionStateNotification,object:previous)
            NotificationCenter.default.addObserver(self,selector:#selector(statusChanged),name:NSWindow.didChangeOcclusionStateNotification,object:window)
        }
        usePanel(desktopPanel,layout:desktopLayout)
        if oldAnchor != nil || desktopPanel.isOnActiveSpace { desktopPanel.orderFrontRegardless() }
        oldAnchor?.close()
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {
        if preferences.overlayCodexUsage || ringIsHidden { openSettings();return false }
        synchronizeSpace()
        if followingCodex { if !panel.isVisible { openSettings() } }
        else if showingFullscreen { reveal(animated:false);moveFullscreenPanelToActiveSpace() }
        else if panel.isOnActiveSpace { restore() }
        return false
    }
    private func updateRingVisibility() {
        guard let content=panel.contentView else { return }
        let hidden=ringIsHidden
        // Keep the desktop window anchored to its Space while hiding its content.
        if content.isHidden != hidden {
            if hidden {
                hideWork?.cancel()
                cancelOverlayNotice()
                ring.dismissHover()
                isDragging=false
            }
            content.isHidden=hidden
        }
        panel.ignoresMouseEvents=hidden
    }
    private func redraw() {
        guard ring != nil else { return }
        updateRingVisibility()
        let visible=displaySnapshot
        let composition=RingComposition(snapshot:visible,preferences:preferences,fiveHourSupport:fiveHourSupport)
        ring.composition=composition
        ring.positionLocked = preferences.effectivePositionLocked
        ring.coversNativeUsage=followingCodex && coveringUsage
        let information=details
        var accessibilityHelp = information.tooltip + "\n" + (coveringUsage ? L10n.string("ring.help.overlay"):(followingCodex ? L10n.string("ring.help.follow"):L10n.string("ring.help.free")))
        if preferences.overlayCodexUsage { accessibilityHelp += "\n" + L10n.string("ring.help.overlayLocked") }
        else if preferences.positionLocked { accessibilityHelp += "\n" + L10n.string("ring.help.locked") }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let surface=followingCodex ? L10n.string("diagnostics.surface.follow"):(showingFullscreen ? L10n.string("diagnostics.surface.fullscreen"):L10n.string("diagnostics.surface.desktop"))
        let diagnostics = L10n.format("diagnostics.window",NSStringFromRect(panel.frame),Int(panel.frame.midX),Int(top - panel.frame.midY),
                                      panel.isOnActiveSpace,panel.isVisible,panel.occlusionState.contains(.visible),isTucked,surface,fullscreenEvidence.text)
        if ProcessInfo.processInfo.arguments.contains("--space-diagnostics"),diagnostics != lastSpaceDiagnostic {
            lastSpaceDiagnostic=diagnostics
            FileHandle.standardError.write(Data(("[space] "+diagnostics.replacingOccurrences(of:"\n",with:" | ")+"\n").utf8))
        }
        if model.diagnostics { accessibilityHelp += "\n" + diagnostics }
        if overlayActive && overlayControlMissing { accessibilityHelp += "\n"+overlayMissingMessage }
        ring.hoverDetails=information.hoverCardText + (preferences.automaticCenter && composition.inner != nil ? "\n"+L10n.format("ring.hover.center",composition.centerPeriod.shortName):"") + (overlayActive && overlayControlMissing ? "\n"+overlayMissingMessage:"")
        ring.setAccessibilityHelp(accessibilityHelp)
        panel.title = "CodexRing"
        model.update(\.snapshot,visible);model.update(\.source,visible.source);model.update(\.isRefreshing,fetching)
        model.update(\.fiveHourSupport,fiveHourSupport)
        model.update(\.overlayAccessibilityGranted,overlayAccessibilityGranted)
        model.update(\.overlayAuthorizationNotice,store.observeAccessibilityTrust(overlayAccessibilityGranted,fingerprint:signingFingerprint)
            ? L10n.string("overlay.updateNotice"):nil)
        model.update(\.overlayStatus,overlayActive && overlayControlMissing ? overlayMissingMessage:"")
        model.update(\.updatedText,dateText(lastRefreshedAt))
        if model.debugState != debugState { model.debugState=debugState }
        model.update(\.diagnosticText,diagnostics)
        let menuData=QuotaMenuPresentation(snapshot:visible,metadata:snapshot,preferences:preferences,
                                          fiveHourSupport:fiveHourSupport,lastRefreshedAt:lastRefreshedAt)
        if model.menuPresentation != menuData { model.menuPresentation=menuData }
        updateMenuBar()
    }
    func applyPreferences(_ requested: RingPreferences) {
        guard requested != preferences else { return }
        let old=preferences
        var value=requested
        value.alerts.normalize()
        if !old.overlayCodexUsage && value.overlayCodexUsage {
            // Request only on an explicit off→on change. Keep the switch off
            // until the OS confirms trust; granting later never enables it.
            overlayAccessibilityGranted=AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary)
        }
        value.reconcileOverlayPermission(granted:overlayAccessibilityGranted)
        preferences=value
        if !old.alerts.enabled && value.alerts.enabled { notifications.requestPermission() }
        if old.bucketID != value.bucketID { notifications.clearBaseline() }
        if old.resetConfetti && !value.resetConfetti { confetti.dismiss() }
        if model.preferences != value { model.preferences=value }
        if old.overlayCodexUsage != value.overlayCodexUsage {
            ring.dismissHover();cancelOverlayNotice();overlayControlMissing=false;overlayNoticeShown=false
        }
        if old.size != value.size || old.overlayCodexUsage != value.overlayCodexUsage { resizeCircle() }
        if !value.autoHide { reveal(animated: false) }
        if old.refreshInterval != value.refreshInterval { configureRefreshTimer() }
        if old.theme != value.theme { applyTheme() }
        if L10n.apply(languageCode:value.languageCode) { applyLanguage() }
        if old.followCodex != value.followCodex || old.overlayCodexUsage != value.overlayCodexUsage {
            codexAction = overlayActive ? .hidden:.free
            codexMonitor.tracksUsageControl=value.overlayCodexUsage
            if value.followCodex || value.overlayCodexUsage { codexMonitor.start();codexMonitor.invalidate() }
            else { codexMonitor.stop() }
        }
        if old.followCodex != value.followCodex || old.overlayCodexUsage != value.overlayCodexUsage
            || old.ringHidden != value.ringHidden || old.hideRingWithoutCodex != value.hideRingWithoutCodex
            || (followingCodex && old.size != value.size) { synchronizeSpace() }
        store.save(preferences); redraw()
    }
    private func applyLanguage() {
        settings?.applyLanguage();debugWindow?.applyLanguage();aboutWindow?.applyLanguage()
        notifications.refreshStatus()
        model.loginStatus=LaunchAtLogin.statusText
        model.objectWillChange.send();model.apiUsage.objectWillChange.send()
    }
    private func resizeCircle() {
        reveal(animated:false)
        let center=NSPoint(x:panel.frame.midX,y:panel.frame.midY)
        let frame=Docking.clamped(NSRect(x:center.x-circleSize/2,y:center.y-circleSize/2,width:circleSize,height:circleSize),to:screenFrame)
        panel.setFrame(frame,display:true);expandedFrame=frame
        material.frame=NSRect(origin:.zero,size:frame.size);material.layer?.cornerRadius=circleSize/2;ring.frame=material.bounds
    }
    private func updateMenuBar() {
        if quotaMenuBar == nil {
            let bar=QuotaMenuBar(model:model)
            bar.onRefresh={ [weak self] in self?.refreshFromMenu() }
            bar.onSettings={ [weak self] in self?.openSettings() }
            bar.onQuit={ [weak self] in self?.quit() }
            quotaMenuBar=bar
        }
        quotaMenuBar?.update(enabled:preferences.showMenuBar)
    }
    private func applyTheme() {
        let appearance:NSAppearance?
        switch preferences.theme { case .system:appearance=nil;case .light:appearance=NSAppearance(named:.aqua);case .dark:appearance=NSAppearance(named:.darkAqua) }
        NSApp.appearance=appearance;panel?.appearance=appearance;settings?.window?.appearance=appearance;debugWindow?.window?.appearance=appearance
        ring?.needsDisplay=true
    }
    private func configureRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer=Timer.scheduledTimer(withTimeInterval:TimeInterval(preferences.refreshInterval.rawValue),repeats:true) { [weak self] _ in self?.refresh() }
    }
    private func savePosition() {
        guard panel != nil else { return }
        let frame:NSRect
        if showingFullscreen || followingCodex { frame=desktopLayout.expandedFrame ?? desktopPanel.frame }
        else { frame=isTucked ? expandedFrame ?? panel.frame:panel.frame }
        preferences.position = PanelPosition(x:frame.origin.x,y:frame.origin.y)
        if model != nil { model.preferences = preferences }; store.save(preferences)
    }
    private func startDrag() { guard !overlayActive else { return };isDragging = true; hideWork?.cancel(); reveal(animated: false) }
    private func finishDrag() {
        isDragging = false
        guard !overlayActive else { return }
        if followingCodex,let area=codexArea {
            preferences.codexAnchor=CodexFollow.anchor(for:panel.frame,in:area)
            model.preferences=preferences;store.save(preferences)
            synchronizeSpace();return
        }
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
        if panel.frame != target { ring.dismissHover() }
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
        guard !ringIsHidden,!followingCodex,panel.isOnActiveSpace,preferences.autoHide,!isDragging,!isTucked,dockEdge != nil,settings?.window?.isVisible != true,debugWindow?.window?.isVisible != true else { return }
        let work=DispatchWorkItem { [weak self] in
            guard let self,self.panel.isOnActiveSpace,let edge=self.dockEdge,let screen=self.dockScreen else { return }
            if !force && self.panel.frame.contains(NSEvent.mouseLocation) { return }
            self.expandedFrame=self.panel.frame; self.isTucked=true
            self.move(to:Docking.hidden(self.panel.frame,edge:edge,screen:screen),animated:true)
        }
        hideWork=work; DispatchQueue.main.asyncAfter(deadline:.now()+0.85,execute:work)
    }
    @objc private func screenChanged() { restore() }
    private func restore() {
        if followingCodex { synchronizeSpace();return }
        hideWork?.cancel(); reveal(animated:false); dockEdge=nil; dockScreen=nil; isTucked=false
        panel.setFrame(Docking.clamped(panel.frame,to:screenFrame),display:true)
        if panel.isOnActiveSpace { panel.orderFrontRegardless() }
        savePosition(); redraw()
    }
    private func refresh() {
        guard source == .official,!fetching,!debugState.isEnabled else { redraw();return }
        fetching=true; redraw(); let request=generation
        DispatchQueue.global(qos:.utility).async { [weak self] in
            guard let self else { return }; let result=self.client.fetch()
            DispatchQueue.main.async { [weak self] in
                guard let self,self.generation == request,self.source == .official else { return }
                self.fetching=false;self.snapshot=result
                if result.failure == nil,!result.loading { self.lastRefreshedAt=result.fetchedAt;self.notifications.observe(result,preferences:self.preferences) }
                self.capabilities.observe(result)
                self.redraw()
            }
        }
    }
    private func connectLive() {
        notifications.clearBaseline()
        generation += 1;client.cancel();source = .official;fetching=false
        snapshot=QuotaSnapshot(source:.official,fetchedAt:Date(),loading:true);refresh()
    }
    private func disconnect() {
        notifications.clearBaseline()
        generation += 1;source = .disconnected;fetching=false;client.cancel()
        snapshot=QuotaSnapshot(source:.disconnected,fetchedAt:Date(),failure:.unavailable);redraw()
    }
    private func applyDebugState(_ value:QuotaDebugState) {
        guard value != debugState else { return }
        let wasEnabled=debugState.isEnabled
        debugState=value
        if value.isEnabled != wasEnabled {
            notifications.clearBaseline()
            debugFallbackFiveHourReset=value.isEnabled ? Date().addingTimeInterval(3600):nil
            generation += 1;client.cancel();fetching=false
        }
        redraw()
        if wasEnabled && !value.isEnabled { refresh() }
    }
    private func openDebug() {
        quotaMenuBar?.close()
        hideWork?.cancel();reveal(animated:false)
        if debugWindow == nil { debugWindow=RingDebugWindow(model:model,onClose:{ [weak self] in self?.scheduleHide() }) }
        redraw();debugWindow?.showWindow(nil);NSApp.activate(ignoringOtherApps:true);debugWindow?.window?.makeKeyAndOrderFront(nil)
    }
    private func handleRingClick() {
        guard coveringUsage,followingCodex else { openSettings();return }
        ring.dismissHover()
        guard panel.isVisible,panel.isOnActiveSpace,let target=codexTarget else { return }
        codexMonitor.pressUsageControl(windowID:target.id) { [weak self] success in
            if !success { self?.model.overlayStatus=L10n.string("overlay.pressFailed") }
        }
    }
    private func openAbout() {
        quotaMenuBar?.close()
        if aboutWindow == nil {
            aboutWindow=RingAboutWindow(onDebug:{ [weak self] in
                self?.aboutWindow?.close()
                self?.openDebug()
            })
        }
        NSApp.activate(ignoringOtherApps:true)
        aboutWindow?.showWindow(nil);aboutWindow?.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func openSettings() {
        quotaMenuBar?.close()
        updateAccessibilityTrust(AXIsProcessTrusted())
        hideWork?.cancel();reveal(animated:false)
        if settings == nil { settings=RingSettingsWindow(model:model,onClose:{ [weak self] in self?.scheduleHide() }) }
        redraw();settings?.showWindow(nil);NSApp.activate(ignoringOtherApps:true);settings?.window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let window=self?.settings?.window,window.isKeyWindow else { return }
            window.makeFirstResponder(nil)
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func refreshFromMenu() { model.apiUsage.refresh();guard !debugState.isEnabled else { return };source == .official ? refresh():connectLive() }
    @objc private func togglePositionLock() {
        guard preferences.canTogglePositionLock else { return }
        var p=preferences;p.togglePositionLock();model.preferences=p
    }
    private func showMenu(event:NSEvent? = nil) {
        guard activeContextMenu == nil else { return }
        ring.dismissHover()
        hideWork?.cancel();reveal(animated:false);let menu=NSMenu();menu.autoenablesItems=false
        for entry in RingMenuSpec.entries(for:preferences) {
            let item:NSMenuItem
            switch entry {
            case .refresh:item=NSMenuItem(title:L10n.string("menu.refreshNow"),action:#selector(refreshFromMenu),keyEquivalent:"r");item.image=NSImage(systemSymbolName:"arrow.clockwise",accessibilityDescription:L10n.string("common.refresh"));item.isEnabled = !fetching && !debugState.isEnabled
            case .settings:item=NSMenuItem(title:L10n.string("menu.settings"),action:#selector(openSettings),keyEquivalent:",")
            case .reset:item=NSMenuItem(title:L10n.string("menu.resetInfo"),action:nil,keyEquivalent:"");item.image=NSImage(systemSymbolName:"arrow.counterclockwise",accessibilityDescription:L10n.string("menu.resetInfo"));item.submenu=resetMenu()
            case .positionLock(let locked):item=NSMenuItem(title:L10n.string("menu.pin"),action:#selector(togglePositionLock),keyEquivalent:"");item.image=NSImage(systemSymbolName:locked ? "pin.fill":"pin",accessibilityDescription:locked ? L10n.string("menu.pin.locked"):L10n.string("menu.pin.unlocked"))
                item.isEnabled=preferences.canTogglePositionLock
                if !item.isEnabled { item.toolTip=L10n.string("menu.pin.overlay") }
            case .hideRing:
                item=NSMenuItem(title:L10n.string("menu.hideRing"),action:#selector(hideRing),keyEquivalent:"")
                item.image=NSImage(systemSymbolName:"eye.slash",accessibilityDescription:item.title)
            case .quit:menu.addItem(.separator());item=NSMenuItem(title:L10n.string("menu.quitShort"),action:#selector(quit),keyEquivalent:"q")
            }
            item.target=self;menu.addItem(item)
        }
        activeContextMenu=menu
        defer { activeContextMenu=nil;synchronizeSpace();scheduleHide() }
        if let event {
            NSMenu.popUpContextMenu(menu,with:event,for:ring)
        } else {
            menu.popUp(positioning:nil,at:NSPoint(x:ring.bounds.midX,y:ring.bounds.midY),in:ring)
        }
    }
    @objc private func hideRing() { model.preferences.ringHidden=true }
    private func resetMenu()->NSMenu {
        let menu=NSMenu(title:L10n.string("menu.resetInfo"));menu.autoenablesItems=false
        let font=NSFont.menuFont(ofSize:0)
        let dateFont=NSFont.monospacedDigitSystemFont(ofSize:12,weight:.regular)
        let pattern=try! NSRegularExpression(pattern:#"\d{4}[.-]\d{2}[.-]\d{2} \d{2}:\d{2}"#)
        let lines=details.resetMenuLines
        let dateColumn=lines.compactMap { line -> CGFloat? in
            let string=line as NSString
            guard let match=pattern.firstMatch(in:line,range:NSRange(location:0,length:string.length)) else { return nil }
            return (string.substring(to:match.range.location) as NSString).size(withAttributes:[.font:font]).width
        }.max() ?? 0
        for line in lines {
            let item=NSMenuItem(title:line,action:nil,keyEquivalent:"");item.isEnabled=false
            let text=NSMutableAttributedString(string:line,attributes:[.font:font])
            for match in pattern.matches(in:line,range:NSRange(location:0,length:(line as NSString).length)) {
                text.addAttribute(.font,value:dateFont,range:match.range)
                // Pad the separator by the measured label width so dates align
                // even when a label mixes Chinese characters and digits.
                if match.range.location>0 {
                    let prefix=(line as NSString).substring(to:match.range.location) as NSString
                    let padding=max(0,dateColumn-prefix.size(withAttributes:[.font:font]).width)
                    text.addAttribute(.kern,value:padding,range:NSRange(location:match.range.location-1,length:1))
                }
            }
            item.attributedTitle=text;menu.addItem(item)
        }
        return menu
    }
}
