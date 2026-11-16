// Compiled by check-codex-follow.sh with the real application sources.
// Exercises only a fixture window and an isolated preference suite.
import AppKit
import ApplicationServices
import QuotaCore

final class FollowCheck:NSObject,NSApplicationDelegate,NSWindowDelegate {
    let suite="local.freeze.codex-ring.follow-check.\(UUID().uuidString)"
    var ring:RingApplication!
    var fixture:NSWindow!
    var preferences=RingPreferences()
    var initialFollowFrame:CGRect?
    var phase="starting"
    var finished=false
    let basic=ProcessInfo.processInfo.arguments.contains("--basic-follow")
    func applicationDidFinishLaunching(_ notification:Notification) {
        guard basic || AXIsProcessTrusted() else { finish("test runner needs Accessibility permission",success:false);return }
        guard let screen=NSScreen.screens.first else { finish("no display",success:false);return }
        preferences.followCodex=true;preferences.size = .large;preferences.autoHide=false;preferences.positionLocked=true
        preferences.position=PanelPosition(x:screen.visibleFrame.minX+30,y:screen.visibleFrame.minY+40)
        let store=PreferencesStore(defaults:UserDefaults(suiteName:suite)!);store.save(preferences)
        ring=RingApplication(store:store,codexMonitor:CodexWindowMonitor(bundleIdentifier:"local.freeze.codex-ring.follow-check",accessibilityTrusted:{ [self] in !basic && AXIsProcessTrusted() }),automaticRefresh:false)
        fixture=NSWindow(contentRect:NSRect(x:screen.visibleFrame.midX-450,y:screen.visibleFrame.midY-300,width:900,height:600),
                         styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        fixture.title="CodexRing 跟随验证（自动关闭）";fixture.isReleasedWhenClosed=false
        fixture.collectionBehavior=[.fullScreenPrimary];fixture.delegate=self
        fixture.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        ring.applicationDidFinishLaunching(notification)
        after(3) { [self] in
            guard checkAttached("ordinary window") else { return }
            NSApp.deactivate()
            after(1) { [self] in testHover { [self] in testSwitches() } }
        }
        after(45) { [self] in finish("timeout in \(phase)",success:false) }
    }
    private func testHover(then completion:@escaping ()->Void) {
        func find(_ view:NSView)->RingView? {
            if let ring=view as? RingView { return ring }
            return view.subviews.compactMap(find).first
        }
        guard let view=NSApp.windows.compactMap({ $0.contentView.flatMap(find) }).first,let owner=view.window else {
            finish("hover: no ring view",success:false);return
        }
        let wasActive=NSApp.isActive
        let keyBefore=NSApp.keyWindow
        let event=NSEvent.enterExitEvent(with:.mouseEntered,location:.zero,modifierFlags:[],timestamp:0,windowNumber:owner.windowNumber,context:nil,eventNumber:0,trackingNumber:0,userData:nil)!
        view.mouseEntered(with:event)
        after(1) { [self] in
            guard let tip=NSApp.windows.first(where:{$0.title == L10n.string("hover.windowTitle") && $0.isVisible}),
                  let label=tip.contentView?.subviews.compactMap({$0 as? NSTextField}).first else {
                finish("hover: card did not appear",success:false);return
            }
            for text in [QuotaPeriod.week.shortName] {
                guard label.stringValue.contains(text) else { finish("hover missing \(text)",success:false);return }
            }
            guard NSApp.isActive == wasActive,NSApp.keyWindow === keyBefore else {
                finish("hover changed input focus",success:false);return
            }
            print("PASS hover visible with all details; active=\(wasActive); focus unchanged")
            view.mouseExited(with:event)
            guard !tip.isVisible else { finish("hover stayed visible after exit",success:false);return }
            print("PASS hover hidden after mouse exit")
            NSApp.activate(ignoringOtherApps:true);fixture.makeKeyAndOrderFront(nil)
            completion()
        }
    }
    private func testSwitches() {
            preferences.followCodex=false;ring.applyPreferences(preferences)
            after(1) { [self] in
                guard checkFree("follow switch off") else { return }
                preferences.followCodex=true;ring.applyPreferences(preferences)
                after(1) { [self] in
                    guard checkAttached("follow switch on") else { return }
                    testMovement()
                }
            }
    }
    private func testMovement() {
            initialFollowFrame=circleFrame()
            fixture.setFrame(fixture.frame.offsetBy(dx:130,dy:60),display:true)
            after(1) { [self] in
                guard checkAttached("moved window"),circleFrame() != initialFollowFrame else { finish("ring did not move",success:false);return }
                fixture.zoom(nil)
                after(1) { [self] in
                    guard checkAttached("zoomed window") else { return }
                    phase="entering fullscreen";fixture.toggleFullScreen(nil)
                }
            }
    }
    func windowDidEnterFullScreen(_ notification:Notification) {
        after(3) { [self] in
            guard checkAttached("native fullscreen") else { return }
            phase="exiting fullscreen";fixture.toggleFullScreen(nil)
        }
    }
    func windowDidExitFullScreen(_ notification:Notification) {
        after(3) { [self] in
            guard checkAttached("restored ordinary window") else { return }
            phase="minimized";fixture.miniaturize(nil)
            after(2) { [self] in
                if basic {
                    guard circleFrame() == nil else { finish("basic minimized ring must remain hidden",success:false);return }
                    print("PASS basic minimized ring hidden")
                } else { guard checkFree("minimized fallback") else { return } }
                fixture.deminiaturize(nil);fixture.makeKeyAndOrderFront(nil)
                after(2) { [self] in
                    guard checkAttached("deminimized window") else { return }
                    fixture.close()
                    fixture=nil // Destroy the window; an ordered-out live window can belong to another Space.
                    after(2) { [self] in
                        guard checkFree("closed fallback") else { return }
                        finish("move, zoom, fullscreen, minimize, reopen and close passed",success:true)
                    }
                }
            }
        }
    }
    private func circleFrame()->CGRect? {
        let records=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        let top=NSScreen.screens.first?.frame.maxY ?? 0
        let frames=records.compactMap { info -> CGRect? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier,
                  let bounds=info[kCGWindowBounds as String] as? [String:Any],
                  let frame=CGRect(dictionaryRepresentation:bounds as CFDictionary),frame.width == 76,frame.height == 76 else { return nil }
            return CGRect(x:frame.minX,y:top-frame.maxY,width:frame.width,height:frame.height)
        }
        // The desktop anchor can remain ordered but transparent; require the
        // actual content-bearing panel, not just any live window rectangle.
        let contentWindows=NSApp.windows.filter { $0 is NSPanel && $0.contentView?.subviews.isEmpty == false && $0.isVisible }
        return contentWindows.compactMap { w in frames.first(where:{$0 == w.frame}) }.first
    }
    private func checkAttached(_ name:String)->Bool {
        guard let frame=circleFrame(),let screen=fixture.screen else { finish("\(name): no visible circle",success:false);return false }
        let area=CodexFollow.area(window:fixture.frame,screen:screen.visibleFrame)
        let expected=CodexFollow.frame(in:area,size:76,anchor:nil)
        guard abs(frame.minX-expected.minX)<2,abs(frame.minY-expected.minY)<2 else {
            finish("\(name): circle \(frame) != expected \(expected)",success:false);return false
        }
        print("PASS \(name): \(frame)");return true
    }
    private func checkFree(_ name:String)->Bool {
        guard let frame=circleFrame(),let position=preferences.position,
              abs(frame.minX-position.x)<2,abs(frame.minY-position.y)<2 else { finish("\(name): free position not restored",success:false);return false }
        print("PASS \(name)");return true
    }
    private func after(_ delay:Double,_ action:@escaping ()->Void) {
        DispatchQueue.main.asyncAfter(deadline:.now()+delay) { [self] in if !finished { action() } }
    }
    private func finish(_ message:String,success:Bool) {
        guard !finished else { return };finished=true
        ring?.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification))
        UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite)
        fixture?.orderOut(nil)
        print("\(success ? "PASS":"FAIL"): \(message)");exit(success ? 0:1)
    }
}
let app=NSApplication.shared
let delegate=FollowCheck()
app.setActivationPolicy(.regular);app.delegate=delegate;app.run()
