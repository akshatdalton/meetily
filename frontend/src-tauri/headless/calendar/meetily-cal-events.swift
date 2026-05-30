// meetily-cal-events — prints today's timed calendar events as TSV:
//   <start_epoch>\t<end_epoch>\t<title>
// Reads the macOS Calendar store via EventKit (so Google/Exchange/iCloud calendars
// that sync into Calendar.app are all visible — no separate API or OAuth).
//
// PERMISSION: EventKit on macOS 14+ requires the *calling bundle's* Info.plist to
// carry NSCalendarsFullAccessUsageDescription (or NSCalendarsUsageDescription).
// A bare CLI binary has none, so this must run from a signed .app bundle (same
// pattern as meetily-rec.app). install.sh wraps it in meetily-cal-events.app.
//
// Build: swiftc -O meetily-cal-events.swift -o meetily-cal-events

import EventKit
import Foundation

let store = EKEventStore()
let sem = DispatchSemaphore(value: 0)
var granted = false

if #available(macOS 14.0, *) {
    store.requestFullAccessToEvents { ok, _ in granted = ok; sem.signal() }
} else {
    store.requestAccess(to: .event) { ok, _ in granted = ok; sem.signal() }
}
sem.wait()

guard granted else {
    FileHandle.standardError.write("meetily-cal-events: calendar access denied\n".data(using: .utf8)!)
    exit(1)
}

let cal = Calendar.current
let startOfDay = cal.startOfDay(for: Date())
guard let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) else { exit(1) }

let pred = store.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
for ev in store.events(matching: pred) {
    if ev.isAllDay { continue }
    guard let s = ev.startDate, let e = ev.endDate else { continue }
    let title = (ev.title ?? "meeting")
        .replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
    print("\(Int(s.timeIntervalSince1970))\t\(Int(e.timeIntervalSince1970))\t\(title)")
}
