import AppKit
import ApplicationServices
import QuotaCore

enum CodexTrackingSnapshot:Equatable {
    case unavailable,waiting
    case windows([CodexFollowWindow],frontPID:pid_t)
    case basicWindows([CodexFollowWindow],frontPID:pid_t)
}

/// Accessibility + WindowServer adapter. AX distinguishes minimized
/// or closed windows from windows on other Spaces; CG supplies global IDs/order.
/// Optional usage-control lookup reads sidebar labels/geometry only.
/// Sampling never clicks or activates windows. A separate explicit user-click
/// path can press the matched usage control; it never synthesizes mouse events.
final class CodexWindowMonitor {
    var onChange:((CodexTrackingSnapshot)->Void)?
    var onAccessibilityChange:((Bool)->Void)?
    var tracksUsageControl=false { didSet { if oldValue != tracksUsageControl { invalidate() } } }
    private var lastTrusted:Bool?
    private let usageLocator=CodexUsageLocator()
    private let applicationRegistry:CodexApplicationRegistry
    private let accessibilityTrusted:()->Bool
    private var timer:Timer?
    private var busy=false
    private var revision=0
    private var last:CodexTrackingSnapshot?
    private var knownWindows:[CodexFollowWindow]=[]
    private var emptySince:Date?
    private var hasObservedWindow=false
    private let queue=DispatchQueue(label:"local.freeze.codex-ring.window-monitor",qos:.userInitiated)
    init(bundleIdentifier:String = "com.openai.codex",accessibilityTrusted:@escaping ()->Bool = { AXIsProcessTrusted() }) {
        self.applicationRegistry=CodexApplicationRegistry(bundleIdentifier:bundleIdentifier)
        self.accessibilityTrusted=accessibilityTrusted
        applicationRegistry.onChange = { [weak self] in self?.invalidate() }
    }
    func start() {
        guard timer == nil else { return }
        applicationRegistry.start()
        last=nil
        let timer=Timer(timeInterval:0.2,repeats:true) { [weak self] _ in self?.sample() }
        self.timer=timer;RunLoop.main.add(timer,forMode:.common);sample()
    }
    func stop() {
        timer?.invalidate();timer=nil;revision += 1;last=nil;knownWindows=[];emptySince=nil;hasObservedWindow=false
        applicationRegistry.stop()
        queue.async { [usageLocator] in usageLocator.reset() }
    }
    deinit { timer?.invalidate() }
    func invalidate() {
        revision += 1;last=nil
        queue.async { [usageLocator] in usageLocator.reset() }
        sample()
    }
    func pressUsageControl(windowID:UInt32,completion:@escaping (Bool)->Void) {
        guard tracksUsageControl,accessibilityTrusted(),
              let target=knownWindows.first(where:{$0.id == windowID && $0.isOnScreen}),
              let frame=target.usageFrame else { completion(false);return }
        let top=NSScreen.screens.first?.frame.maxY ?? 0
        let expected=CGRect(x:frame.minX,y:top-frame.maxY,width:frame.width,height:frame.height)
        let request=revision
        queue.async { [weak self] in
            guard let self else { return }
            // Reject a queued click after a Space change or tracking switch.
            let valid=DispatchQueue.main.sync { self.revision == request && self.tracksUsageControl && self.accessibilityTrusted() }
            let success=valid && self.usageLocator.press(id:windowID,expectedFrame:expected)
            DispatchQueue.main.async { completion(success) }
        }
    }
    private func publish(_ value:CodexTrackingSnapshot) {
        guard value != last else { return };last=value
        if ProcessInfo.processInfo.arguments.contains("--space-diagnostics") {
            FileHandle.standardError.write(Data(("[follow] \(value)\n").utf8))
        }
        onChange?(value)
    }
    private func sample() {
        guard timer != nil,!busy else { return }
        let trusted=accessibilityTrusted()
        if lastTrusted != trusted { lastTrusted=trusted;onAccessibilityChange?(trusted) }
        // Losing permission can disable overlay tracking in the callback.
        guard timer != nil else { return }
        let apps=applicationRegistry.applications
        // Hiding/backgrounding the app does not close its windows. Never turn
        // that into a free desktop ring merely because the app is not visible.
        if !apps.isEmpty,apps.allSatisfy(\.isHidden) { emptySince=nil;publish(.waiting);return }
        let pids=apps.map(\.processIdentifier)
        let top=NSScreen.screens.first?.frame.maxY ?? 0
        let front=NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let request=revision
        let previous=knownWindows
        let observed=hasObservedWindow
        let locateUsage=tracksUsageControl
        let locator=usageLocator
        busy=true
        queue.async { [weak self] in
            let valid=DispatchQueue.main.sync {
                guard let self else { return false }
                return self.timer != nil && self.revision == request
                    && (!locateUsage || (self.tracksUsageControl && self.accessibilityTrusted()))
            }
            guard valid else {
                DispatchQueue.main.async { self?.busy=false }
                return
            }
            var value=trusted ? Self.read(pids:pids,top:top,front:front,previous:previous,locator:locateUsage ? locator:nil)
                : Self.readBasic(pids:pids,top:top,front:front,previous:previous,hasObservedWindow:observed)
            if locateUsage,case .unavailable=value {
                // An unavailable accessibility tree must not remove the fallback
                // ring. Public window metadata can still place a normal ring;
                // it never supplies or guesses a native control's coordinates.
                value=Self.readBasic(pids:pids,top:top,front:front,previous:previous,hasObservedWindow:observed)
            }
            let sampled=value
            DispatchQueue.main.async {
                guard let self else { return };self.busy=false
                guard self.timer != nil,self.revision == request else { return }
                let windows:[CodexFollowWindow]?
                switch sampled {
                case .windows(let values,_),.basicWindows(let values,_):windows=values
                default:windows=nil
                }
                if let windows {
                    if windows.isEmpty,!pids.isEmpty {
                        let since=self.emptySince ?? Date();self.emptySince=since
                        if Date().timeIntervalSince(since)<1.2 { self.publish(.waiting);return }
                    } else { self.emptySince=nil }
                    self.knownWindows=windows
                    if windows.contains(where:\.isOnScreen) { self.hasObservedWindow=true }
                }
                self.publish(sampled)
            }
        }
    }
    private static func attribute(_ element:AXUIElement,_ name:CFString)->CFTypeRef? {
        var value:CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,name,&value) == .success else { return nil }
        return value
    }
    private static func readBasic(pids:[pid_t],top:CGFloat,front:pid_t,previous:[CodexFollowWindow],hasObservedWindow:Bool)->CodexTrackingSnapshot {
        guard !pids.isEmpty else { return .basicWindows([],frontPID:front) }
        guard let records=CGWindowListCopyWindowInfo([.optionAll,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] else { return .unavailable }
        let candidates=records.compactMap { info -> CodexFollowWindow? in
            guard let pid=(info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,pids.contains(pid),
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)>0,
                  let id=(info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds=info[kCGWindowBounds as String] as? [String:Any],
                  let frame=CGRect(dictionaryRepresentation:bounds as CFDictionary),
                  CodexFollow.isContentWindow(frame:frame) else { return nil }
            return CodexFollowWindow(id:id,frame:CGRect(x:frame.minX,y:top-frame.maxY,width:frame.width,height:frame.height),
                isOnScreen:(info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true)
        }
        let windows=CodexFollow.basicWindows(candidates:candidates,previous:previous,hasObservedWindow:hasObservedWindow)
        return .basicWindows(windows,frontPID:front)
    }
    private static func read(pids:[pid_t],top:CGFloat,front:pid_t,previous:[CodexFollowWindow],locator:CodexUsageLocator?)->CodexTrackingSnapshot {
        guard !pids.isEmpty else { locator?.reset();return .windows([],frontPID:front) }
        guard let records=CGWindowListCopyWindowInfo([.optionAll,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] else { return .unavailable }
        var result:[CodexFollowWindow]=[]
        for pid in pids {
            let app=AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app,0.2)
            // read() runs only with AX trust, and locator exists only when the
            // user has selected usage overlay. Basic following never enables
            // the Electron renderer's accessibility tree.
            locator?.prepare(application:app,pid:pid)
            guard let windows=attribute(app,kAXWindowsAttribute as CFString) as? [AXUIElement] else { return .unavailable }
            if windows.isEmpty {
                let registered=Set(records.compactMap { info -> UInt32? in
                    guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else { return nil }
                    return (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
                })
                result += CodexFollow.retainedOffscreenWindows(previous:previous,registeredIDs:registered)
                continue
            }
            let focused=attribute(app,kAXFocusedWindowAttribute as CFString)
            for window in windows.prefix(32) {
                var values:CFArray?
                let names=[kAXPositionAttribute,kAXSizeAttribute,kAXMinimizedAttribute,kAXSubroleAttribute,kAXModalAttribute] as CFArray
                guard AXUIElementCopyMultipleAttributeValues(window,names,[],&values) == .success,
                      let fields=values as? [AnyObject],fields.count == 5 else { return .unavailable }
                if (fields[2] as? NSNumber)?.boolValue == true { continue }
                if (fields[4] as? NSNumber)?.boolValue == true { continue }
                if let role=fields[3] as? String,role != (kAXStandardWindowSubrole as String) { continue }
                guard CFGetTypeID(fields[0]) == AXValueGetTypeID(),CFGetTypeID(fields[1]) == AXValueGetTypeID() else { continue }
                var origin=CGPoint.zero,size=CGSize.zero
                guard AXValueGetValue(fields[0] as! AXValue,.cgPoint,&origin),
                      AXValueGetValue(fields[1] as! AXValue,.cgSize,&size) else { continue }
                let axFrame=CGRect(origin:origin,size:size)
                guard CodexFollow.isContentWindow(frame:axFrame) else { continue }
                let matches=records.compactMap { info -> CodexFollowWindow? in
                    guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                          (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                          ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)>0,
                          let id=(info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                          let bounds=info[kCGWindowBounds as String] as? [String:Any],
                          let frame=CGRect(dictionaryRepresentation:bounds as CFDictionary),
                          abs(frame.minX-axFrame.minX)<3,abs(frame.minY-axFrame.minY)<3,
                          abs(frame.width-axFrame.width)<3,abs(frame.height-axFrame.height)<3 else { return nil }
                    let converted=CGRect(x:frame.minX,y:top-frame.maxY,width:frame.width,height:frame.height)
                    return CodexFollowWindow(id:id,frame:converted,
                        isOnScreen:(info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                        isFocused:focused.map { CFEqual($0,window) } ?? false)
                }
                // During a fullscreen animation AX and CG can briefly disagree.
                // Wait for a consistent sample instead of treating that as closure.
                guard var match=matches.first(where:\.isOnScreen) ?? matches.first else { return .unavailable }
                if match.isOnScreen,let rect=locator?.locate(in:window,application:app,id:match.id,bounds:axFrame) {
                    match.usageFrame=CGRect(x:rect.minX,y:top-rect.maxY,width:rect.width,height:rect.height)
                }
                result.append(match)
            }
        }
        let order=records.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        locator?.retain(windowIDs:Set(result.map(\.id)))
        result.sort { (order.firstIndex(of:$0.id) ?? Int.max)<(order.firstIndex(of:$1.id) ?? Int.max) }
        return .windows(result,frontPID:front)
    }
}
