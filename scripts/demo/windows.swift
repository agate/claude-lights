// Prints on-screen windows as JSON lines: {"id","owner","name","layer","x","y","w","h"} in points.
//   windows [owner-substring]
import CoreGraphics
import Foundation

let filter = CommandLine.arguments.dropFirst().first
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    if let filter, !owner.localizedCaseInsensitiveContains(filter) { continue }
    guard let b = w[kCGWindowBounds as String] as? [String: Double] else { continue }
    let row: [String: Any] = [
        "id": w[kCGWindowNumber as String] as? Int ?? 0, "owner": owner,
        "name": w[kCGWindowName as String] as? String ?? "", "layer": w[kCGWindowLayer as String] as? Int ?? 0,
        "x": b["X"] ?? 0, "y": b["Y"] ?? 0, "w": b["Width"] ?? 0, "h": b["Height"] ?? 0,
    ]
    let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

// windows --status-item <pid>: also print the app's menu bar status item frame via Accessibility.
import ApplicationServices

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--status-item",
   let pid = pid_t(CommandLine.arguments[2]) {
    let app = AXUIElementCreateApplication(pid)
    var bar: CFTypeRef?
    AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar)
    var kids: CFTypeRef?
    if let bar { AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids) }
    for item in (kids as? [AXUIElement]) ?? [] {
        var pos: CFTypeRef?, size: CFTypeRef?
        AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &pos)
        AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size)
        var p = CGPoint.zero, s = CGSize.zero
        if let pos { AXValueGetValue(pos as! AXValue, .cgPoint, &p) }
        if let size { AXValueGetValue(size as! AXValue, .cgSize, &s) }
        print("{\"status_item\":true,\"x\":\(p.x),\"y\":\(p.y),\"w\":\(s.width),\"h\":\(s.height)}")
    }
}
