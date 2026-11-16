// Native integration check. Only creates/moves its own fixture, never Codex.
import AppKit
import ApplicationServices
import QuotaCore

final class OverlayCheck:NSObject,NSApplicationDelegate {
    let suite="local.freeze.codex-ring.overlay-check.\(UUID().uuidString)"
    var ring:RingApplication!
    var fixture:NSWindow!
    var button:NSButton!
    var preferences=RingPreferences()
    var noticeCount=0
    var pressCount=0
    var trusted=true
    var finished=false
    func applicationDidFinishLaunching(_ notification:Notification) {
        guard AXIsProcessTrusted(),let screen=NSScreen.screens.first else { finish("runner requires existing AX trust",false);return }
        preferences.overlayCodexUsage=true;preferences.size = .large;preferences.autoHide=false
        preferences.position=PanelPosition(x:screen.visibleFrame.minX+30,y:screen.visibleFrame.minY+40)
        let store=PreferencesStore(defaults:UserDefaults(suiteName:suite)!);store.save(preferences)
        fixture=NSWindow(contentRect:NSRect(x:screen.visibleFrame.minX+200,y:screen.visibleFrame.minY+180,width:800,height:500),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        fixture.title="CodexRing 覆盖验证（自动关闭）";fixture.isReleasedWhenClosed=false
        button=NSButton(frame:NSRect(x:8,y:52,width:36,height:36));button.title="用量";button.toolTip="原生用量提示";button.target=self;button.action=#selector(usagePressed)
        fixture.contentView?.addSubview(button)
        fixture.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        ring=RingApplication(store:store,codexMonitor:CodexWindowMonitor(bundleIdentifier:"local.freeze.codex-ring.overlay-check",accessibilityTrusted:{ [self] in trusted }),automaticRefresh:false,onOverlayUnavailable:{ [weak self] in self?.noticeCount += 1 })
        ring.applicationDidFinishLaunching(notification)
        after(2) { [self] in
            guard attached("initial overlay") else { return }
            testInteraction { [self] in
            fixture.setFrame(fixture.frame.offsetBy(dx:100,dy:40),display:true)
            after(1) { [self] in
                guard attached("window moved") else { return }
                button.setFrameOrigin(NSPoint(x:28,y:72))
                after(1) { [self] in
                    guard attached("control moved within window") else { return }
                    testMissingControl { [self] in
                        after(1) { [self] in
                            guard attached("control reappeared") else { return }
                            trusted=false
                            after(1) { [self] in
                                guard normal("permission revoked") else { return }
                                guard !store.load().overlayCodexUsage else { finish("permission loss did not turn off saved overlay switch",false);return }
                                trusted=true
                                after(1) { [self] in
                                    guard normal("permission restored without reenabling") else { return }
                                    ring.applyPreferences(preferences)
                                    after(1) { [self] in
                                        guard attached("manually reenabled after permission restored") else { return }
                                        preferences.overlayCodexUsage=false;ring.applyPreferences(preferences)
                                        after(1) { [self] in
                                            guard normal("overlay disabled") else { return }
                                            finish("overlay geometry, hover interception, forwarded click, visible fallback and notice, permission loss and size/position restoration",true)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        }
        after(45) { [self] in finish("timeout",false) }
    }
    func testMissingControl(_ completion:@escaping ()->Void) {
        func fallback()->Bool {
            guard let window=circle(),window.frame.width == 76,
                  fixture.frame.contains(window.frame),!window.ignoresMouseEvents else {
                finish("missing control did not preserve normal-size ring",false);return false
            }
            guard let view=window.contentView?.subviews.first?.subviews.first as? RingView,
                  !view.coversNativeUsage,
                  view.hoverDetails.contains("未找到 Codex 额度控件") else {
                finish("fallback still forwards clicks or lacks explanation",false);return false
            }
            return true
        }
        button.removeFromSuperview()
        after(1) { [self] in
            guard fallback(),noticeCount == 0 else { return }
            fixture.contentView?.addSubview(button)
            after(3.5) { [self] in
                guard attached("brief disappearance recovered"),noticeCount == 0 else {
                    finish("brief disappearance raised a delayed warning",false);return
                }
                button.removeFromSuperview()
                after(4) { [self] in
                    guard fallback(),noticeCount == 1 else { finish("persistent disappearance did not notify once",false);return }
                    after(3.5) { [self] in
                        guard fallback(),noticeCount == 1 else { finish("repeated missing-control warning",false);return }
                        print("PASS visible fallback, warning debounce, single notice, normal hover and no click forwarding")
                        fixture.contentView?.addSubview(button)
                        completion()
                    }
                }
            }
        }
    }
    @objc func usagePressed() { pressCount += 1 }
    func testInteraction(_ completion:@escaping ()->Void) {
        func find(_ view:NSView)->RingView? {
            if let ring=view as? RingView { return ring }
            return view.subviews.compactMap(find).first
        }
        guard let window=circle(),let view=window.contentView.flatMap(find) else { finish("missing ring view",false);return }
        let event=NSEvent.enterExitEvent(with:.mouseEntered,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,trackingNumber:0,userData:nil)!
        view.mouseEntered(with:event)
        after(0.6) { [self] in
            guard NSApp.windows.contains(where:{$0.title == "CodexRing 额度详情" && $0.isVisible}),pressCount == 0 else { finish("hover missing or unexpectedly clicked",false);return }
            print("PASS hover shows own tip without clicking native control")
            _=view.accessibilityPerformPress()
            after(0.7) { [self] in
                guard pressCount == 1,!NSApp.windows.contains(where:{$0.title == "CodexRing 额度详情" && $0.isVisible}) else { finish("click was not forwarded once or hover stayed visible",false);return }
                let saved=PreferencesStore(defaults:UserDefaults(suiteName:suite)!).load()
                guard saved.codexAnchor == preferences.codexAnchor else { finish("click modified normal follow position",false);return }
                print("PASS click forwarded once; hover dismissed; normal anchor preserved")
                testContextMenus(view,completion)
            }
        }
    }
    func testContextMenus(_ view:RingView,_ completion:@escaping ()->Void) {
        guard let window=view.window else { finish("context menu missing window",false);return }
        for controlClick in [false,true] {
            var opened:NSMenu?,wasStable=false
            let observer=NotificationCenter.default.addObserver(forName:NSMenu.didBeginTrackingNotification,object:nil,queue:nil) { notification in
                guard let menu=notification.object as? NSMenu,menu.item(withTitle:"重置信息") != nil else { return }
                opened=menu
                // App activation caused by a background context menu must not
                // hide/reparent the panel while its native menu tracks input.
                NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.didActivateApplicationNotification,object:nil)
            }
            let timer=Timer(timeInterval:0.6,repeats:false) { _ in
                wasStable=opened != nil && window.isVisible
                opened?.cancelTracking()
            }
            RunLoop.main.add(timer,forMode:.eventTracking)
            let event=NSEvent.mouseEvent(with:controlClick ? .leftMouseDown:.rightMouseDown,
                                        location:NSPoint(x:view.bounds.midX,y:view.bounds.midY),
                                        modifierFlags:controlClick ? [.control]:[],timestamp:ProcessInfo.processInfo.systemUptime,
                                        windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
            if controlClick { view.mouseDown(with:event);view.mouseUp(with:event) }
            else { view.rightMouseDown(with:event) }
            timer.invalidate();NotificationCenter.default.removeObserver(observer)
            guard wasStable,pressCount == 1 else { finish("\(controlClick ? "Control-click":"right-click") context menu failed or triggered native usage",false);return }
            print("PASS \(controlClick ? "Control-click":"right-click") menu remains open across activation; no native click")
        }
        completion()
    }
    func circle()->NSWindow? {
        NSApp.windows.first { $0 is NSPanel && $0.isVisible && $0.contentView?.subviews.isEmpty == false && $0.title == "CodexRing" }
    }
    func attached(_ name:String)->Bool {
        let control=fixture.convertToScreen(button.convert(button.bounds,to:nil))
        guard let window=circle(),window.frame.width == 26,!window.ignoresMouseEvents,
              abs(window.frame.midX-control.midX)<1,abs(window.frame.midY-control.midY)<1 else { finish("\(name): incorrect overlay \(String(describing:circle()?.frame)) / control \(control)",false);return false }
        print("PASS \(name): \(window.frame), interceptsMouse=true");return true
    }
    func normal(_ name:String)->Bool {
        guard let window=circle(),let position=preferences.position,window.frame.width == 76,!window.ignoresMouseEvents,
              abs(window.frame.minX-position.x)<1,abs(window.frame.minY-position.y)<1 else { finish("\(name): normal placement not restored \(String(describing:circle()?.frame))",false);return false }
        print("PASS \(name)");return true
    }
    func after(_ delay:Double,_ action:@escaping ()->Void) {
        DispatchQueue.main.asyncAfter(deadline:.now()+delay) { [self] in if !finished { action() } }
    }
    func finish(_ message:String,_ success:Bool) {
        guard !finished else { return };finished=true
        ring?.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification))
        UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite)
        fixture?.orderOut(nil);print("\(success ? "PASS":"FAIL"): \(message)");exit(success ? 0:1)
    }
}
let app=NSApplication.shared,delegate=OverlayCheck()
app.setActivationPolicy(.regular);app.delegate=delegate;app.run()
