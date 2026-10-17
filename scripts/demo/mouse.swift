// Synthetic mouse and keyboard for the demo recording.
//   mouse move <x> <y> [seconds]   glide the cursor (points, top-left origin)
//   mouse click <x> <y>            move there instantly and left-click
//   mouse drag <x1> <y1> <x2> <y2>  press at (x1, y1), glide to (x2, y2), release
//   mouse scroll <dy> [steps]      scroll the window under the cursor
//   mouse key <keycode>            press and release one key (53 = Escape)
import CoreGraphics
import Foundation

func post(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

func current() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

let args = CommandLine.arguments.dropFirst().map { $0 }
guard let cmd = args.first else { exit(2) }
let nums = args.dropFirst().compactMap(Double.init)

switch cmd {
case "move":
    let to = CGPoint(x: nums[0], y: nums[1])
    let seconds = nums.count > 2 ? nums[2] : 0.6
    let from = current()
    let steps = max(1, Int(seconds * 60))
    for i in 1...steps {
        // ease in-out so the motion reads as a person's hand
        let t = Double(i) / Double(steps)
        let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        post(.mouseMoved, CGPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e))
        usleep(UInt32(1_000_000 / 60))
    }
case "click":
    let p = CGPoint(x: nums[0], y: nums[1])
    post(.mouseMoved, p)
    usleep(60_000)
    post(.leftMouseDown, p)
    usleep(70_000)
    post(.leftMouseUp, p)
case "drag":
    let a = CGPoint(x: nums[0], y: nums[1]), b = CGPoint(x: nums[2], y: nums[3])
    post(.mouseMoved, a)
    usleep(100_000)
    post(.leftMouseDown, a)
    usleep(150_000)
    for i in 1...40 {
        let t = Double(i) / 40
        post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        usleep(16_000)
    }
    usleep(150_000)
    post(.leftMouseUp, b)
case "scroll":
    let dy = Int32(nums[0])
    let steps = nums.count > 1 ? Int(nums[1]) : 20
    for _ in 0..<steps {
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy / Int32(steps),
                wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
        usleep(16_000)
    }
case "key":
    let code = CGKeyCode(nums[0])
    CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
default:
    exit(2)
}
