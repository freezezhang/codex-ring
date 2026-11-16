// Opt-in desktop integration check. Creates and fullscreens only its own fixture
// window, then checks CodexRing's WindowServer visibility and restored position.
// Run after launching CodexRing: swift scripts/check-fullscreen.swift
import AppKit

final class FullscreenCheck:NSObject,NSApplicationDelegate,NSWindowDelegate {
    private var window:NSWindow!
    private var original:[CGRect]=[]
    private var finished=false
    private var ringPID:pid_t=0
    func applicationDidFinishLaunching(_ notification:Notification) {
        guard let ring=NSWorkspace.shared.runningApplications.first(where:{$0.bundleIdentifier == "local.freeze.codex-quota-ring"}),
              let screen=NSScreen.screens.last else { finish("CodexRing must be running",success:false);return }
        ringPID=ring.processIdentifier
        let frame=NSRect(x:screen.visibleFrame.midX-320,y:screen.visibleFrame.midY-200,width:640,height:400)
        window=NSWindow(contentRect:frame,styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title="CodexRing 全屏验证（自动关闭）"
        window.collectionBehavior=[.fullScreenPrimary];window.delegate=self
        window.isReleasedWhenClosed=false
        let label=NSTextField(labelWithString:"正在验证圆圈进入全屏后可见、退出后恢复位置。\n测试窗口会自动关闭。")
        label.frame=NSRect(x:40,y:140,width:560,height:80);window.contentView?.addSubview(label)
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        after(4) { [self] in
            print("fixture: active=\(NSApp.isActive), onSpace=\(window.isOnActiveSpace), visible=\(window.occlusionState.contains(.visible)), frame=\(NSStringFromRect(window.frame))")
            original=ringFrames()
            guard original.count<=1 else { finish("ordinary desktop: duplicate rings",success:false);return }
            print("ordinary desktop: \(original)")
            window.toggleFullScreen(nil)
        }
        after(25) { [self] in finish("fullscreen transition timeout",success:false) }
    }
    func windowDidEnterFullScreen(_ notification:Notification) {
        after(4) { [self] in
            let frames=ringFrames()
            guard frames.count == 1 else { finish("fullscreen: expected one visible ring",success:false);return }
            let frame=frames[0]
            guard let screen=window.screen,let primary=NSScreen.screens.first else { finish("missing fullscreen display",success:false);return }
            let display=CGRect(x:screen.frame.minX,y:primary.frame.maxY-screen.frame.maxY,width:screen.frame.width,height:screen.frame.height)
            guard window.styleMask.contains(.fullScreen),display.contains(frame) else {
                finish("ring did not follow the native fullscreen display",success:false);return
            }
            report("native fullscreen",frame)
            window.toggleFullScreen(nil)
        }
    }
    func windowDidExitFullScreen(_ notification:Notification) {
        after(4) { [self] in
            let frames=ringFrames()
            print("returned to desktop: \(frames)")
            // Zero is correct when the home desktop is inactive on another
            // monitor. Returning must preserve its absence, too.
            let restored=frames == original
            finish(restored ? "visible in native fullscreen; desktop visibility/position restored":"desktop visibility/position changed",success:restored)
        }
    }
    private func ringFrames()->[CGRect] {
        let windows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        let frames=windows.compactMap { info -> CGRect? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ringPID,
                  let bounds=info[kCGWindowBounds as String] as? [String:Any],
                  let rect=CGRect(dictionaryRepresentation:bounds as CFDictionary),
                  rect.width >= 20,rect.width <= 200,rect.height >= 20,rect.height <= 200 else { return nil }
            return rect
        }
        print("ring onscreen count: \(frames.count)")
        return frames
    }
    private func after(_ delay:Double,_ block:@escaping ()->Void) {
        DispatchQueue.main.asyncAfter(deadline:.now()+delay) { [self] in if !finished { block() } }
    }
    private func report(_ phase:String,_ frame:CGRect) { print("\(phase): \(NSStringFromRect(frame))") }
    private func finish(_ message:String,success:Bool) {
        guard !finished else { return };finished=true
        print("\(success ? "PASS":"FAIL"): \(message)")
        window?.orderOut(nil)
        exit(success ? 0:1)
    }
}
let app=NSApplication.shared
let delegate=FullscreenCheck()
app.setActivationPolicy(.regular);app.delegate=delegate;app.run()
