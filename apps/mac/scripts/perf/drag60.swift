import CoreGraphics
import Foundation

let a = CommandLine.arguments.dropFirst().compactMap(Double.init)
guard a.count >= 5 else { print("usage: drag60 x y dx dy n [hz]"); exit(2) }
let (x, y, dx, dy, n) = (a[0], a[1], a[2], a[3], Int(a[4]))
let period = 1.0 / (a.count > 5 ? a[5] : 60)
let oneWay = a.count > 6 && a[6] == 1
let src = CGEventSource(stateID: .hidSystemState)
func post(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}
let start = CGPoint(x: x, y: y)
post(.mouseMoved, start)
usleep(50_000)
post(.leftMouseDown, start)
var points: [CGPoint] = []
for i in 1...n { points.append(CGPoint(x: x + dx * Double(i) / Double(n), y: y + dy * Double(i) / Double(n))) }
if !oneWay { for i in stride(from: n - 1, through: 0, by: -1) { points.append(CGPoint(x: x + dx * Double(i) / Double(n), y: y + dy * Double(i) / Double(n))) } }
let t0 = CFAbsoluteTimeGetCurrent()
for (k, p) in points.enumerated() {
    let due = t0 + Double(k + 1) * period
    let wait = due - CFAbsoluteTimeGetCurrent()
    if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
    post(.leftMouseDragged, p)
}
usleep(30_000)
post(.leftMouseUp, points.last ?? start)
print(String(format: "posted %d drags in %.2fs", points.count, CFAbsoluteTimeGetCurrent() - t0))
