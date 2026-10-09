// runawake: a menu-bar app that prevents Mac sleep (idle system sleep) only while a command runs
// in the foreground of a terminal or an AI agent is responding. It does not keep the display on.
// - Agents with hooks: detected via "busy" marks that hooks/runawake-mark puts in ~/.runawake/busy/ (registered by hooks/setup.py)
// - Agents whose hooks can't report start/end of a response: detected by CPU use of the process tree, held awake for a while after last activity
// Sessions that are merely open and waiting are not counted.
import Cocoa
import IOKit.pwr_mgt
import IOKit.ps
import Network

let pollSeconds: TimeInterval = 5
// Display language: Japanese if the system's primary language is Japanese, otherwise English (override with `defaults write local.runawake lang en` or the launch argument `-lang en`)
let isJa = (UserDefaults.standard.string(forKey: "lang") ?? Locale.preferredLanguages.first ?? "en").hasPrefix("ja")
func T(_ ja: String, _ en: String) -> String { isJa ? ja : en }
// Agents detected via hooks. Commands inside their trees are excluded from terminal detection (counted on the agent side).
let hookedAgents: Set<String> = ["claude", "codex", "agy", "antigravity", "gemini", "copilot", "opencode"]
// Process name -> name used in hook marks
let hookName: [String: String] = ["agy": "antigravity"]
/// Whether that agent's hooks actually run (runawake-mark touches ~/.runawake/hooks-ok/<name>).
/// If they do, use hook marks; if not (unregistered or unapproved), fall back to CPU detection.
func hooksWorking(_ procName: String) -> Bool {
    let name = hookName[procName] ?? procName
    let path = NSHomeDirectory() + "/.runawake/hooks-ok/" + name
    guard let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return false }
    return Date().timeIntervalSince(m) < 14 * 86400
}
// Agents detected by CPU, because they have no hooks or their hooks don't fire at response start/end.
let cpuAgents: Set<String> = ["cursor-agent", "aider", "goose", "amp", "droid", "crush", "qwen", "kiro-cli", "auggie"]
let cpuBusySeconds = 0.25          // CPU use above this in one poll (5s) counts as "active"
let cpuHoldSeconds: TimeInterval = 10 * 60  // Waiting on an API uses no CPU, so stay awake for a while after last activity
// Safety net for marks whose idle signal never came (e.g. interrupted). A single model call rarely lasts longer.
let staleMarkSeconds: TimeInterval = 20 * 60
// Treated as "just waiting" even in the foreground. Add more to ~/.runawake/ignore, one per line.
let defaultIgnore: Set<String> = [
    "zsh", "-zsh", "bash", "-bash", "fish", "sh", "login", "tmux", "screen",
    "vim", "nvim", "vi", "less", "more", "man", "ssh", "mosh-client",
    "top", "htop", "btop", "caffeinate",
]
let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "Python"]

struct Proc {
    let pid: Int32, ppid: Int32, stat: String, tty: String, name: String, cpu: Double
    let agent: String?
}

func loadIgnore() -> Set<String> {
    let path = NSHomeDirectory() + "/.runawake/ignore"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return defaultIgnore }
    let extra = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    return defaultIgnore.union(extra)
}

/// Convert ps TIME (e.g. "1:15.74", "12:01:15.74", "2-03:04:05") to seconds.
func parseCPUTime(_ s: Substring) -> Double {
    var days = 0.0, rest = s
    if let dash = s.firstIndex(of: "-") { days = Double(s[..<dash]) ?? 0; rest = s[s.index(after: dash)...] }
    var total = 0.0
    for part in rest.split(separator: ":") { total = total * 60 + (Double(part) ?? 0) }
    return days * 86400 + total
}

/// Work out the agent name from arguments. For things run via node or python, look at the script name.
func agentName(_ args: [Substring]) -> String? {
    guard let first = args.first else { return nil }
    let exe = (String(first) as NSString).lastPathComponent
    if first.contains("/claude/versions/") { return "claude" }
    if hookedAgents.contains(exe) || cpuAgents.contains(exe) { return exe }
    if interpreters.contains(exe), let script = args.dropFirst().first(where: { !$0.hasPrefix("-") }) {
        let base = ((String(script) as NSString).lastPathComponent as NSString).deletingPathExtension
        if hookedAgents.contains(base) || cpuAgents.contains(base) { return base }
    }
    return nil
}

func listProcs() -> [Proc] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-axo", "pid=,ppid=,stat=,tty=,time=,args="]
    let pipe = Pipe()
    p.standardOutput = pipe
    do { try p.run() } catch { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(decoding: data, as: UTF8.self)
    return out.split(separator: "\n").compactMap { line in
        let f = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
        guard f.count == 6, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { return nil }
        let args = f[5].split(separator: " ")
        let name = (String(args.first ?? "") as NSString).lastPathComponent
        return Proc(pid: pid, ppid: ppid, stat: String(f[2]), tty: String(f[3]), name: name,
                    cpu: parseCPUTime(f[4]), agent: agentName(args))
    }
}

/// "Busy" marks left by hooks. Drop marks whose owner pid is gone or that haven't been updated for long.
func busyMarkedAgents() -> [String] {
    let dir = NSHomeDirectory() + "/.runawake/busy"
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
    var out: [String] = []
    for n in names.sorted() {
        let path = dir + "/" + n
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        let f = text.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        let mtime = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        guard let pid = Int32(f.first ?? ""), kill(pid, 0) == 0, Date().timeIntervalSince(mtime) < staleMarkSeconds else {
            try? fm.removeItem(atPath: path); continue
        }
        let agent = displayName(f.count > 1 ? f[1] : "agent")
        let place = f.count > 2 ? (f[2].hasPrefix("/") ? shortPath(f[2]) : (f[2].isEmpty ? nil : f[2])) : nil
        out.append(describe(who: agent, what: T(" が作業中", " working"), place: place))
    }
    return out
}

/// Display name: map internal names (process name / hook agent name) to human-readable ones.
let displayNames: [String: String] = [
    "claude": "Claude Code", "codex": "Codex", "agy": "Antigravity", "antigravity": "Antigravity",
    "gemini": "Gemini CLI", "cursor": "Cursor", "cursor-agent": "Cursor CLI", "copilot": "Copilot CLI",
    "opencode": "OpenCode", "aider": "Aider", "goose": "Goose", "amp": "Amp", "droid": "Droid",
    "crush": "Crush", "qwen": "Qwen Code", "kiro-cli": "Kiro CLI", "auggie": "Auggie",
]
func displayName(_ raw: String) -> String { displayNames[raw] ?? raw }

/// Shorten home to ~. nil if empty.
func shortPath(_ path: String) -> String? {
    let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if p.isEmpty { return nil }
    let home = NSHomeDirectory()
    if p == home { return "~" }
    if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
    return p
}

/// The process's working directory (nil if unavailable).
func cwd(of pid: Int32) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
}

/// Collapse identical lines into one with a count (e.g. 3 Claude Code sessions in the same folder).
func merged(_ lines: [String]) -> [String] {
    var order: [String] = [], count: [String: Int] = [:]
    for l in lines { if count[l] == nil { order.append(l) }; count[l, default: 0] += 1 }
    return order.map { count[$0]! > 1 ? "\($0)" + T("(\(count[$0]!)セッション)", " (\(count[$0]!) sessions)") : $0 }
}

func describe(who: String, what: String, place: String?) -> String {
    place.map { "\(who)\(what) — \($0)" } ?? "\(who)\(what)"
}

final class Detector {
    var lastTreeCPU: [Int32: Double] = [:]
    var lastActive: [Int32: Date] = [:]
    var termCPU: [Int32: Double] = [:]
    var termActive: [Int32: Date] = [:]
    var termFirstSeen: [Int32: Date] = [:]
    /// Whether Capsomnia is running. It keeps resetting disablesleep to 0 while Caps Lock is OFF, which conflicts with lid mode.
    var capsomniaRunning = false

    func scan(ignore: Set<String>) -> [String] {
        let procs = listProcs()
        capsomniaRunning = procs.contains { $0.name == "Capsomnia" }
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var children: [Int32: [Int32]] = [:]
        for p in procs { children[p.ppid, default: []].append(p.pid) }
        func agentAncestor(_ p: Proc) -> Proc? {
            var cur = byPid[p.ppid], hops = 0
            while let c = cur, hops < 64 { if c.agent != nil { return c }; cur = byPid[c.ppid]; hops += 1 }
            return nil
        }
        func treeCPU(_ root: Int32) -> Double {
            var stack = [root], total = 0.0
            while let x = stack.popLast() { total += byPid[x]?.cpu ?? 0; stack += children[x] ?? [] }
            return total
        }

        // CPU-detected agents (per outermost process whose parent is not an agent)
        var reasons: [String] = []
        var alive = Set<Int32>()
        let now = Date()
        for p in procs {
            // Agents with working hooks are counted by marks, so only CPU-detected ones here.
            // For agents without hooks or with unapproved hooks, only look at interactive sessions in a terminal (with a tty), to avoid false positives from daemons
            guard let name = p.agent, agentAncestor(p) == nil else { continue }
            if hookedAgents.contains(name) && (hooksWorking(name) || p.tty == "??") { continue }
            alive.insert(p.pid)
            let cpu = treeCPU(p.pid)
            if let prev = lastTreeCPU[p.pid], cpu - prev >= cpuBusySeconds { lastActive[p.pid] = now }
            lastTreeCPU[p.pid] = cpu
            if let t = lastActive[p.pid], now.timeIntervalSince(t) < cpuHoldSeconds {
                reasons.append(describe(who: displayName(name), what: T(" が動作中", " running"), place: cwd(of: p.pid).flatMap(shortPath)))
            }
        }
        lastTreeCPU = lastTreeCPU.filter { alive.contains($0.key) }
        lastActive = lastActive.filter { alive.contains($0.key) }

        // Commands running in the terminal foreground (excluding agents and their descendants)
        // A foreground command counts only while it actually does something: it used CPU in the last
        // 10 minutes, or it started less than 10 minutes ago. A `cat` or `read` waiting for input forever does not count.
        var seen: [String: String] = [:]
        var termAlive = Set<Int32>()
        for p in procs where p.stat.contains("+") && p.tty.hasPrefix("tty") {
            if seen[p.tty] != nil || ignore.contains(p.name) || p.agent != nil || agentAncestor(p) != nil { continue }
            termAlive.insert(p.pid)
            let cpu = treeCPU(p.pid)
            if termFirstSeen[p.pid] == nil { termFirstSeen[p.pid] = now }
            if let prev = termCPU[p.pid], cpu - prev >= 0.05 { termActive[p.pid] = now }
            termCPU[p.pid] = cpu
            let recent = [termFirstSeen[p.pid], termActive[p.pid]].compactMap { $0 }.contains { now.timeIntervalSince($0) < cpuHoldSeconds }
            if !recent { continue }
            seen[p.tty] = describe(who: T("ターミナルで ", ""), what: T("\(p.name) を実行中", "\(p.name) running in Terminal"), place: cwd(of: p.pid).flatMap(shortPath))
        }
        termCPU = termCPU.filter { termAlive.contains($0.key) }
        termActive = termActive.filter { termAlive.contains($0.key) }
        termFirstSeen = termFirstSeen.filter { termAlive.contains($0.key) }
        return reasons + seen.sorted { $0.key < $1.key }.map { $0.value }
    }
}

/// Log state changes to ~/.runawake/log, one per line (recreated when over 1MB).
func logLine(_ text: String) {
    if CommandLine.arguments.contains("--demo-wake") || CommandLine.arguments.contains("--demo-wake-png") { return }
    let dir = NSHomeDirectory() + "/.runawake", path = dir + "/log"
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int), size > 1_000_000 { try? fm.removeItem(atPath: path) }
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date())) \(text)\n"
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
}

/// Prevent sleep even with the lid closed (pmset disablesleep). Needs root, so the user adds one NOPASSWD line to sudoers.
enum Lid {
    static let setupHint = T("初回だけ管理者設定が必要です。ターミナルで次を実行してください(パスワードを聞かれます):", "Run this once in Terminal (you will be asked for your password):") + """


    sudo sh -c 'echo "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0" > /etc/sudoers.d/runawake && chmod 440 /etc/sudoers.d/runawake && visudo -cf /etc/sudoers.d/runawake'
    """
    @discardableResult
    static func set(_ disabled: Bool) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { logLine(T("蓋モード: sudo を起動できない: \(error)", "Lid mode: could not launch sudo: \(error)")); return false }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        p.waitUntilExit()
        let ok = p.terminationStatus == 0
        if !ok || !text.isEmpty { logLine(T("蓋モード: pmset exit=\(p.terminationStatus) \(text)", "Lid mode: pmset exit=\(p.terminationStatus) \(text)")) }
        if ok && current() != disabled { logLine(T("蓋モード: 設定したのに反映されていない(SleepDisabled=\(current()))", "Lid mode: setting did not take effect (SleepDisabled=\(current()))")) }
        return ok
    }
    /// Current SleepDisabled value
    static func current() -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["-g"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return text.split(separator: "\n").first { $0.contains("SleepDisabled") }?.contains("1") ?? false
    }
    static var available: Bool {  // Whether the sudoers entry exists (tested by setting it to 0; no side effects)
        return Lid.set(false)
    }
}

/// Lid closed with no external display: the Mac is in a bag or on a desk unattended.
/// Uses the online display list rather than NSScreen, which can still list the built-in panel while it is off.
/// `defaults write local.runawake lidTest -bool true` pretends the lid is closed (for testing; never sleeps the Mac).
func closedAway() -> Bool {
    if UserDefaults.standard.bool(forKey: "lidTest") { return true }
    guard lidClosed() else { return false }
    var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &ids, &n) == .success else { return NSScreen.screens.isEmpty }
    return !ids.prefix(Int(n)).contains { CGDisplayIsBuiltin($0) == 0 && CGDisplayIsAsleep($0) == 0 }
}

/// Lid closed and no external display online at all (asleep or not). Used for putting the Mac to sleep
/// and for the wake card, where a docked Mac whose external display merely went to sleep must not count.
func closedNoExternal() -> Bool {
    if UserDefaults.standard.bool(forKey: "lidTest") { return true }
    guard lidClosed() else { return false }
    var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &ids, &n) == .success else { return NSScreen.screens.isEmpty }
    return !ids.prefix(Int(n)).contains { CGDisplayIsBuiltin($0) == 0 }
}
/// Any external display that is on (so someone is at a desk with this Mac).
func externalDisplayAwake() -> Bool {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &ids, &n) == .success else { return false }
    return ids.prefix(Int(n)).contains { CGDisplayIsBuiltin($0) == 0 && CGDisplayIsAsleep($0) == 0 }
}

/// Whether the lid is closed (AppleClamshellState of IOPMrootDomain).
func lidClosed() -> Bool {
    let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard entry != 0 else { return false }
    defer { IOObjectRelease(entry) }
    let v = IORegistryEntryCreateCFProperty(entry, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    return (v as? Bool) ?? false
}

/// When the lid opens or the Mac wakes, show a card in the center of the screen about what happened while closed. Moving the mouse dismisses it.
struct WakeReport {
    let from: Date, to: Date, minutes: Int
    let slept: Bool               // the Mac slept at some point while away
    var worked = false            // runawake kept it awake for part of the time (so "finished" is meaningful)
    var sleptAt: Date? = nil      // when it fell asleep, if it worked first
    var lidWasClosed = true       // false: it idle-slept with the lid open
    let before: [String]          // What was running just before closing
    let now: [String]             // What is running now
    var heatStop: Date? = nil     // When it stopped midway due to heat
}

extension NSFont {
    func withRoundedDesign() -> NSFont {
        guard let d = fontDescriptor.withDesign(.rounded) else { return self }
        return NSFont(descriptor: d, size: pointSize) ?? self
    }
}

final class WakeNote {
    var panel: NSPanel?
    var monitors: [Any] = []
    var timer: Timer?

    func show(_ r: WakeReport, attempt: Int = 0) {
        dismiss()
        // Right after wake, external displays may not be back yet. Retry every 2s for up to 1 minute until a screen is found.
        // Show it on the screen with the mouse (the one touched to wake = the one being looked at).
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens.first else {
            if attempt < 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.show(r, attempt: attempt + 1) }
            } else {
                logLine(T("復帰のお知らせ: 画面が見つからず出せなかった", "Wake summary: no screen found, not shown"))
            }
            return
        }

        // One calm card. No color; text weight alone conveys "how long, what finished, what remains".
        let width: CGFloat = 420, pad: CGFloat = 24
        let innerW = width - pad * 2
        let f = DateFormatter(); f.dateFormat = "H:mm"

        // Finished = present before closing and gone now. Remaining = present now.
        func key(_ s: String) -> String {  // Treat entries differing only by "(3 sessions)" as the same
            s.replacingOccurrences(of: #"(\(\d+セッション\)| \(\d+ sessions\))$"#, with: "", options: .regularExpression)
        }
        let nowKeys = Set(r.now.map(key))
        // Phrase finished items as nouns rather than "... running" (e.g. rsync in Terminal / Claude Code's work)
        func past(_ e: String) -> String {
            var parts = e.components(separatedBy: " — ")
            var w = parts[0]
            if w.hasPrefix("ターミナルで "), w.hasSuffix(" を実行中") { w = "ターミナルの " + w.dropFirst(7).dropLast(5) }
            else if w.hasSuffix(" が作業中") { w = w.dropLast(5) + " の作業" }
            else if w.hasSuffix(" が動作中") { w = String(w.dropLast(5)) }
            else if w.hasSuffix(" running in Terminal") { w = String(w.dropLast(20)) + " in Terminal" }
            else if w.hasSuffix(" working") { w = String(w.dropLast(8)) }
            else if w.hasSuffix(" running") { w = String(w.dropLast(8)) }
            parts[0] = w
            return parts.joined(separator: " — ")
        }
        // Nothing ran while asleep, so nothing can have finished; everything from before is simply paused.
        let finished = (r.slept && !r.worked) ? [] : r.before.filter { !nowKeys.contains(key($0)) }.map(past)
        let running = r.now

        var rows: [(NSView, CGFloat, CGFloat)] = []   // (view, height, top margin)

        func text(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, w: CGFloat, truncateHead: Bool = false) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = NSFont.systemFont(ofSize: size, weight: weight); l.textColor = color
            l.lineBreakMode = truncateHead ? .byTruncatingHead : .byTruncatingTail
            l.maximumNumberOfLines = 1
            l.frame.size = NSSize(width: w, height: ceil(l.sizeThatFits(NSSize(width: w, height: 100)).height))
            return l
        }

        // Heading: a big "46 min", "with the lid closed" beside it, time range and a note below. Small app icon at top left
        let head = NSView(frame: NSRect(x: 0, y: 0, width: innerW, height: 48))
        let num = NSTextField(labelWithString: "\(r.minutes)")
        num.font = NSFont.systemFont(ofSize: 40, weight: .thin).withRoundedDesign()
        num.textColor = .labelColor; num.sizeToFit()
        num.frame.origin = NSPoint(x: 0, y: 0)
        head.addSubview(num)
        let unit = text(r.lidWasClosed ? T("分、閉じていました", "min with the lid closed") : T("分、眠っていました", "min asleep"), size: 14, weight: .medium, color: .secondaryLabelColor, w: innerW - num.frame.width - 50)
        unit.frame.origin = NSPoint(x: num.frame.width + 4, y: 8)
        head.addSubview(unit)
        let icon = NSImageView(frame: NSRect(x: innerW - 30, y: 14, width: 30, height: 30))
        icon.image = NSApp.applicationIconImage; icon.alphaValue = 0.9
        head.addSubview(icon)
        rows.append((head, 48, 0))
        let note: String
        if !r.slept { note = T("Mac は起きたまま作業を続けていました", "Your Mac stayed awake and kept working") }
        else if r.worked, let at = r.sleptAt { note = T("\(f.string(from: at)) まで作業し、終わってから眠りました", "Worked until \(f.string(from: at)), then went to sleep") }
        else { note = T("Mac は眠っていたため、作業は止まっていました", "Your Mac was asleep, so work was paused") }
        let sub = text("\(f.string(from: r.from)) – \(f.string(from: r.to))　·　" + note,
                       size: 12, color: .secondaryLabelColor, w: innerW)
        rows.append((sub, sub.frame.height, 4))
        let line = NSBox(); line.boxType = .custom; line.borderWidth = 0; line.fillColor = NSColor.white.withAlphaComponent(0.10)
        line.frame = NSRect(x: 0, y: 0, width: innerW, height: 1)
        rows.append((line, 1, 16))

        // List: thin gray symbols only
        func section(_ heading: String, _ items: [String], symbol: String) {
            guard !items.isEmpty else { return }
            let h = text(heading, size: 11, weight: .medium, color: .secondaryLabelColor, w: innerW)
            rows.append((h, h.frame.height, rows.count == 3 ? 14 : 18))
            for e in items {
                let parts = e.components(separatedBy: " — ")
                let rowH: CGFloat = 20
                let v = NSView(frame: NSRect(x: 0, y: 0, width: innerW, height: rowH))
                let icon = NSImageView(frame: NSRect(x: 0, y: 3, width: 14, height: 14))
                icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
                icon.contentTintColor = .secondaryLabelColor
                v.addSubview(icon)
                let what = text(parts[0], size: 13, color: .labelColor, w: innerW - 22)
                what.sizeToFit()
                what.frame.size.width = min(what.frame.width, (innerW - 22) * 0.6)
                what.frame.origin = NSPoint(x: 22, y: (rowH - what.frame.height) / 2)
                v.addSubview(what)
                if parts.count > 1 {
                    let x = 22 + what.frame.width + 8
                    let place = text(parts[1...].joined(separator: " — "), size: 12, color: .tertiaryLabelColor, w: innerW - x, truncateHead: true)
                    place.frame.origin = NSPoint(x: x, y: (rowH - place.frame.height) / 2)
                    v.addSubview(place)
                }
                rows.append((v, rowH, 4))
            }
        }
        if let h = r.heatStop {
            let warn = text(T("\(f.string(from: h)) に Mac が熱くなったため、途中で止めて休ませました", "Your Mac got hot at \(f.string(from: h)), so it was allowed to rest"), size: 12, weight: .medium, color: .labelColor, w: innerW)
            rows.append((warn, warn.frame.height, 12))
        }
        section(T("終わったもの", "Finished"), finished, symbol: "checkmark")
        let paused = r.slept && !r.worked
        section(paused ? T("まだ終わっていないもの(閉じている間は止まっていました)", "Not finished (paused while closed)") : T("まだ動いているもの", "Still running"),
                paused ? Array(Set(r.before + running)).sorted() : running, symbol: "circle.dotted")
        if finished.isEmpty && running.isEmpty && !(paused && !r.before.isEmpty) {
            let none = text(T("動いていたものはありません", "Nothing was running"), size: 13, color: .secondaryLabelColor, w: innerW)
            rows.append((none, none.frame.height, 14))
        }

        let total = rows.reduce(pad * 2) { $0 + $1.1 + $1.2 }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: total))
        var y = total - pad
        for (v, h, top) in rows { y -= top + h; v.frame.origin = NSPoint(x: pad, y: y); root.addSubview(v) }

        let effect = NSVisualEffectView(frame: root.frame)
        // Frosted glass (darkish) + hairline border. Appearance fixed to dark so it looks the same on any wallpaper
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
        effect.wantsLayer = true; effect.layer?.cornerRadius = 18; effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5; effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        effect.addSubview(root)

        let vf = screen.visibleFrame
        // Center of the screen, slightly above (eye level)
        let origin = NSPoint(x: vf.midX - width / 2, y: vf.midY - total / 2 + vf.height * 0.08)
        let p = NSPanel(contentRect: NSRect(origin: origin, size: effect.frame.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.ignoresMouseEvents = true
        p.contentView = effect
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.35; p.animator().alphaValue = 1 }
        panel = p
        logLine(T("復帰のお知らせを表示: \(screen.localizedName)", "Wake summary shown: \(screen.localizedName)") + (attempt > 0 ? T("(画面を\(attempt)回待った)", " (waited for screen \(attempt) times)") : ""))
        // --demo-wake-png <path>: render the card to an image (for checking the look; no screen-recording permission needed)
        if let i = CommandLine.arguments.firstIndex(of: "--demo-wake-png"), i + 1 < CommandLine.arguments.count {
            if let rep = effect.bitmapImageRepForCachingDisplay(in: effect.bounds) {
                effect.cacheDisplay(in: effect.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            }
        }

        // Give time to read: a click or key dismisses it (after 1s). Mouse movement alone won't dismiss it until 10s pass. Auto-dismisses after 2 min.
        let shownAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.panel === p else { return }
            let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
            let handle: (NSEvent) -> Void = { [weak self] e in
                if e.type == .mouseMoved || e.type == .scrollWheel, Date().timeIntervalSince(shownAt) < 10 { return }
                self?.dismiss()
            }
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handle) { self.monitors.append(m) }
            if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { e in handle(e); return e }) { self.monitors.append(m) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in self?.dismiss() }
    }

    func dismiss() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        timer?.invalidate(); timer = nil
        if panel != nil { logLine(T("復帰のお知らせを閉じた", "Wake summary closed")) }
        if let p = panel {
            panel = nil
            NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.4; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
        }
    }
}


final class App: NSObject, NSApplicationDelegate {
    let item: NSStatusItem = {
        let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        i.autosaveName = "runawake"
        // The icon is the only UI, so it must never go missing: if it was ⌘-dragged off the menu bar
        // (macOS remembers that as "NSStatusItem Visible runawake" = 0), bring it back, and disallow removal.
        i.behavior = []
        i.isVisible = true
        return i
    }()
    var lidDisabled = false   // Whether pmset disablesleep is currently 1
    var lidMode: Bool {
        get { UserDefaults.standard.bool(forKey: "lid") }
        set { UserDefaults.standard.set(newValue, forKey: "lid") }
    }
    var assertion: IOPMAssertionID = 0
    var holding = false
    var paused = false
    let detector = Detector()
    let wakeNote = WakeNote()
    var awayStart: Date?          // When the lid closed / Mac slept
    var awaySnapshot: [String] = []
    var awaySlept = false
    var awayWorked = false        // we held the Mac awake at some point during this away period
    var awaySleptAt: Date?
    var awayLidClosed = false
    var demoNow: [String]?
    /// Between willSleep and didWake. Maintenance (dark) wakes run our timer too; holding or setting disablesleep then
    /// would keep a closed Mac awake in a bag. So while "sleeping", never hold.
    var sleeping = false
    var lidCheckAt = Date.distantPast
    let isDemo = CommandLine.arguments.contains("--demo-wake") || CommandLine.arguments.contains("--demo-wake-png")
    // Heat guard: stop keeping awake when macOS thermal state reaches "serious" or higher. Resume only after 5 min back at "nominal"
    var overheated = false
    var heatStoppedAt: Date?
    var coolSince: Date?
    var heatGuardEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "heatGuard") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "heatGuard") }
    }
    /// Thermal state (can be overridden for testing with defaults thermalOverride 0-3)
    var thermal: ProcessInfo.ThermalState {
        if let v = UserDefaults.standard.object(forKey: "thermalOverride") as? Int, let t = ProcessInfo.ThermalState(rawValue: v) { return t }
        return ProcessInfo.processInfo.thermalState
    }
    /// Battery level (0-100) and whether the Mac runs on battery. nil when there is no battery.
    func battery() -> (percent: Int, onBattery: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onBattery = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            return (cur * 100 / max, onBattery)
        }
        return nil
    }
    /// Hard cap: with the lid closed on battery, stop after 3 hours no matter what is "running".
    var lidOnBatterySince: Date?
    var capped = false
    func checkLidCap() {
        let closedOnBattery = closedAway() && (battery()?.onBattery ?? false)
        if closedOnBattery {
            if lidOnBatterySince == nil { lidOnBatterySince = Date() }
            if !capped, Date().timeIntervalSince(lidOnBatterySince!) >= 3 * 3600 {
                capped = true
                logLine(T("上限: 蓋を閉じて電池で3時間たったので、起こすのをやめる", "Limit: 3 hours with the lid closed on battery, stopped keeping awake"))
            }
        } else {
            lidOnBatterySince = nil
            if capped { capped = false }
        }
    }
    var lowBattery = false
    var lowBatteryAt: Date?
    /// Network: AI agents cannot work offline, so after 10 minutes without a connection they no longer keep the Mac awake.
    /// (Terminal commands still count; a local build does not need the network.)
    let netMonitor = NWPathMonitor()
    var offlineSince: Date?
    var offlineLong: Bool { offlineSince.map { Date().timeIntervalSince($0) >= 10 * 60 } ?? false }
    /// With the lid closed, losing the network for 3 minutes means "on the move": stop and let the Mac sleep.
    var offlineClosed: Bool { closedAway() && (offlineSince.map { Date().timeIntervalSince($0) >= 3 * 60 } ?? false) }
    var loggedOfflineClosed = false
    var loggedOffline = false
    var batteryFloor: Int { (UserDefaults.standard.object(forKey: "batteryFloor") as? Int) ?? 20 }
    /// On battery at or below the floor: stop keeping the Mac awake. Resumes when plugged in.
    func checkBattery() {
        guard let b = battery() else { lowBattery = false; return }
        if b.onBattery && b.percent <= batteryFloor {
            if !lowBattery {
                lowBattery = true; lowBatteryAt = Date()
                logLine(T("電池の見張り: 電池が \(b.percent)% になったので、起こすのをやめる", "Battery guard: battery at \(b.percent)%, stopped keeping awake"))
            }
        } else if lowBattery && !b.onBattery {
            lowBattery = false; logLine(T("電池の見張り: 電源につながったので再開", "Battery guard: plugged in, resuming"))
        }
    }

    func checkHeat() {
        guard heatGuardEnabled else { overheated = false; return }
        let t = thermal
        // With the lid closed (e.g. in a bag) the Mac cools poorly, so stop already at "fair"
        let limit: ProcessInfo.ThermalState = (closedAway()) ? .fair : .serious
        if t.rawValue >= limit.rawValue {
            coolSince = nil
            if !overheated {
                overheated = true; heatStoppedAt = Date()
                logLine(T("熱の見張り: Mac が熱くなった(熱状態=\(t.rawValue))ので、起こすのをやめて休ませる", "Heat guard: Mac got hot (thermal state=\(t.rawValue)), stopped keeping awake to let it rest"))
            }
        } else if overheated {
            if t.rawValue < limit.rawValue {
                if coolSince == nil { coolSince = Date() }
                if Date().timeIntervalSince(coolSince!) >= 5 * 60 { overheated = false; coolSince = nil; logLine(T("熱の見張り: 冷えたので再開", "Heat guard: cooled down, resuming")) }
            } else { coolSince = nil }
        }
    }
    var warnedCapsomnia = false
    var wakeNoteEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "wakeNote") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "wakeNote") }
    }
    var reasons: [String] = []
    var menuSignature = ""
    // While keeping awake, slowly fade the icon in and out (breathing, not blinking). Can be turned off from the menu.
    var pulseEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "pulse") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "pulse") }
    }

    /// Plays the icon animation while something runs. Frames go straight into a layer's contents,
    /// which is far cheaper than swapping the status button's image (that re-lays out the menu bar each time).
    var animTimer: Timer?
    var animFrame = 0
    var animLayer: CALayer?
    var animCG: [CGImage] = []
    var animCGDark: Bool?
    var animCGFor = ""
    /// Which character lives in the menu bar (menu: Icon).
    var critter: Critter { Critter.named(UserDefaults.standard.string(forKey: "critter")) }
    func setRunning(_ running: Bool, still: NSImage) {
        guard let button = item.button else { return }
        if running && pulseEnabled {
            let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if animCGDark != dark || animCGFor != critter.id { animCG = critter.run.compactMap { Draw.tinted($0, dark ? .white : .black) }; animCGDark = dark; animCGFor = critter.id }
            if animLayer == nil {
                button.wantsLayer = true
                let l = CALayer()
                l.contentsGravity = .center
                l.contentsScale = 2
                button.layer?.addSublayer(l)
                animLayer = l
            }
            button.image = Draw.blank
            animLayer?.frame = button.bounds
            animLayer?.isHidden = false
            if animTimer == nil {
                animTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
                    guard let self, !self.animCG.isEmpty else { return }
                    self.animFrame = (self.animFrame + 1) % self.animCG.count
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    self.animLayer?.contents = self.animCG[self.animFrame]
                    CATransaction.commit()
                }
                RunLoop.main.add(animTimer!, forMode: .common)   // keep running while the menu is open
            }
        } else {
            animTimer?.invalidate(); animTimer = nil
            animLayer?.isHidden = true
            button.image = running ? critter.run[min(2, critter.run.count - 1)] : still
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        if let url = Bundle.main.url(forResource: "runawake", withExtension: "icns"), let img = NSImage(contentsOf: url) { NSApp.applicationIconImage = img }
        if isDemo {
            // The demo only renders the card. It must not touch sleep settings, hold assertions or show a second menu bar icon.
            item.isVisible = false
            awayStart = Date().addingTimeInterval(-46 * 60); awaySlept = CommandLine.arguments.contains("--slept"); awayLidClosed = true
            if CommandLine.arguments.contains("--worked") { awayWorked = true; awaySleptAt = Date().addingTimeInterval(-12 * 60) }
            if CommandLine.arguments.contains("--heat") { heatStoppedAt = Date().addingTimeInterval(-20 * 60) }
            awaySnapshot = [T("ターミナルで rsync を実行中", "rsync running in Terminal") + " — ~/backup", "Claude Code" + T(" が作業中", " working") + " — ~/src/myapp", "Codex" + T(" が作業中", " working") + " — ~/src/api"]
            // The demo shows a fixed example rather than the real state (so local paths don't appear in the image)
            demoNow = awaySlept ? [] : ["Claude Code" + T(" が作業中", " working") + " — ~/src/myapp", "Codex" + T(" が作業中", " working") + " — ~/src/api"]
            endAway()
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in if self?.wakeNote.panel == nil { NSApp.terminate(nil) } }
            return
        }
        logLine(T("起動", "Started"))
        // Quit via SIGTERM (launchctl bootout, pkill) skips applicationWillTerminate, so reset disablesleep here too
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak self] in if self?.lidDisabled == true { Lid.set(false) }; logLine(T("終了(SIGTERM)", "Quit (SIGTERM)")); exit(0) }
        term.resume(); sigterm = term
        // If disablesleep was left on after a previous crash, reset it
        if lidMode, Lid.set(false) { logLine(T("蓋モード: 起動時に disablesleep を 0 に戻した", "Lid mode: reset disablesleep to 0 at startup")) }
        netMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                if path.status == .satisfied && !UserDefaults.standard.bool(forKey: "offlineTest") {
                    if self.loggedOffline { logLine(T("ネット: つながったので AI エージェントも数える", "Network: back online, counting AI agents again")) }
                    self.offlineSince = nil; self.loggedOffline = false
                } else if self.offlineSince == nil { self.offlineSince = Date() }
            }
        }
        netMonitor.start(queue: .global(qos: .utility))
        tick()
        Timer.scheduledTimer(withTimeInterval: pollSeconds, repeats: true) { [weak self] _ in self?.tick() }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.tick() }
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self, let r = self.pendingReport else { return }
            self.pendingReport = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.wakeNote.show(r) }
        }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sleeping = true
            self.beginAway(slept: true)
            // Release everything now so a maintenance wake cannot pick it back up
            self.setHold(false); self.applyLid()
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = false
            // Marks and process states shift right after wake, so wait a bit before polling
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.tick(); self?.endAway() }
        }
    }

    /// Lid closed (no external display) or Mac slept. Record what was going on.
    func beginAway(slept: Bool) {
        guard awayStart == nil else {
            if slept, !awaySlept { awaySlept = true; awaySleptAt = Date(); logLine(T("スリープへ", "Going to sleep")) }
            return
        }
        awayStart = Date(); awaySlept = slept; awaySnapshot = reasons
        awayWorked = false; awaySleptAt = nil; awayLidClosed = !slept
        logLine((slept ? T("スリープへ", "Going to sleep") : T("蓋を閉じた", "Lid closed")) + T(" — 動いていたもの: ", " — running: ") + (reasons.isEmpty ? T("なし", "none") : reasons.joined(separator: " / ")))
    }

    /// Lid opened / Mac woke. If away for 1 min or more, show what happened in the center of the screen.
    func endAway() {
        guard let start = awayStart else { return }
        let mins = Int(Date().timeIntervalSince(start) / 60)
        awayStart = nil
        logLine((awaySlept ? T("復帰", "Woke") : T("蓋を開けた", "Lid opened")) + T(" (\(mins)分)", " (\(mins) min)"))
        guard wakeNoteEnabled, mins >= 1 else { return }
        let report = WakeReport(from: start, to: Date(), minutes: mins, slept: awaySlept, worked: awayWorked, sleptAt: awaySleptAt,
                                 lidWasClosed: awayLidClosed, before: awaySnapshot, now: demoNow ?? reasons,
                                 heatStop: heatStoppedAt.flatMap { $0 >= start ? $0 : nil })
        // On wake the lock screen comes first, and typing the password would dismiss the card at once.
        // So while the screen is locked, keep the card and show it right after the unlock.
        if screenIsLocked() { pendingReport = report; logLine(T("復帰のお知らせ: ロック解除を待つ", "Wake summary: waiting for unlock")) }
        else { wakeNote.show(report) }
    }

    var pendingReport: WakeReport?
    var sigterm: DispatchSourceSignal?
    func screenIsLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    func applicationWillTerminate(_ n: Notification) {
        if lidDisabled { Lid.set(false) }
        logLine(T("終了", "Quit"))
    }

    func tick() {
        var found = busyMarkedAgents() + detector.scan(ignore: loadIgnore())
        if offlineLong {
            if !loggedOffline { logLine(T("ネット: 10分以上つながっていないので、AI エージェントは数えない", "Network: offline for 10+ minutes, not counting AI agents")); loggedOffline = true }
            found = found.filter { $0.contains(T("ターミナル", "in Terminal")) }
        }
        reasons = paused ? [] : merged(found)
        if UserDefaults.standard.bool(forKey: "offlineTest") { offlineSince = Date().addingTimeInterval(-11 * 60) }
        checkHeat()
        checkBattery()
        checkLidCap()
        if offlineClosed != loggedOfflineClosed {
            loggedOfflineClosed = offlineClosed
            if offlineClosed { logLine(T("ネット: 蓋を閉じたまま3分つながらないので、止めて寝かせる", "Network: offline for 3 minutes with the lid closed, stopping so the Mac sleeps")) }
        }
        // Lid open or an external display on means someone is here: not a dark wake in a bag
        if sleeping && (!lidClosed() || externalDisplayAwake()) { sleeping = false }
        setHold(!reasons.isEmpty && !overheated && !lowBattery && !capped && !offlineClosed && !sleeping)
        if holding, awayStart != nil { awayWorked = true }
        applyLid()
        // Lid closed with no external display counts as "away". (Using clamshell mode with an external display is not away)
        let closed = closedNoExternal()
        if closed, awayStart == nil { beginAway(slept: false) }
        if closed, awayStart != nil { awayLidClosed = true }
        if !closed, awayStart != nil, !awaySlept { endAway() }
        render()
    }

    /// disablesleep 1 only while lid mode is on and keeping awake; otherwise reset to 0.
    func applyLid() {
        var want = lidMode && holding && !paused
        if want && detector.capsomniaRunning {
            // Capsomnia resets it to 0 within seconds, so do nothing to avoid a tug-of-war
            if !warnedCapsomnia { logLine(T("蓋モード: Capsomnia が動いているため効きません(Capsomnia が disablesleep を戻すため)", "Lid mode: no effect because Capsomnia is running (Capsomnia resets disablesleep)")); warnedCapsomnia = true }
            want = false
        }
        // Another tool (or a stray instance) may have reset disablesleep under us: re-check once a minute
        if want, lidDisabled, Date().timeIntervalSince(lidCheckAt) > 60 {
            lidCheckAt = Date()
            if !Lid.current() { logLine(T("蓋モード: 外から 0 に戻されていたので入れ直す", "Lid mode: disablesleep was reset externally, setting it again")); lidDisabled = false }
        }
        guard want != lidDisabled else { return }
        if Lid.set(want) {
            lidDisabled = want
            logLine(want ? T("蓋モード: 蓋を閉じても寝ないようにした", "Lid mode: Mac will stay awake with the lid closed") : T("蓋モード: 通常に戻した", "Lid mode: back to normal"))
            // If work finishes with the lid closed, macOS won't trigger lid-closed sleep again, so put it to sleep ourselves
            if !want && !sleeping && closedNoExternal() && !UserDefaults.standard.bool(forKey: "lidTest") {
                logLine(T("作業が終わり蓋が閉じているので、スリープさせる", "Work finished with the lid closed, putting Mac to sleep"))
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["sleepnow"]
                try? p.run()
            }
        }
        else { logLine(T("蓋モード: pmset に失敗(sudoers 未設定?)", "Lid mode: pmset failed (sudoers not set up?)")) }
    }

    func setHold(_ on: Bool) {
        if on == holding { return }
        if on {
            let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "runawake: command or AI session running" as CFString, &assertion)
            holding = (r == kIOReturnSuccess)
            logLine(T("起こし始めた: ", "Started keeping awake: ") + reasons.joined(separator: " / "))
        } else {
            IOPMAssertionRelease(assertion)
            holding = false
            logLine(T("起こすのをやめた", "Stopped keeping awake"))
        }
    }

    func render() {
        // The chosen icon: animated while something runs, still when idle, crossed out when off.
        let desc = "runawake: " + (paused ? T("オフ", "off") : (holding ? T("Mac を起こしています", "keeping your Mac awake") : T("待機中", "idle")))
        item.button?.title = ""
        item.button?.toolTip = desc
        item.button?.setAccessibilityLabel(desc)
        setRunning(holding && !paused, still: paused ? critter.off : critter.idle)

        let signature = [desc, reasons.joined(separator: "|"), "\(lowBattery)\(overheated)\(lidMode)\(detector.capsomniaRunning)\(wakeNoteEnabled)\(heatGuardEnabled)\(pulseEnabled)\(critter.id)"].joined(separator: "#")
        if signature == menuSignature { return }
        menuSignature = signature
        let menu = NSMenu()
        func note(_ text: String) { menu.addItem(withTitle: text, action: nil, keyEquivalent: "") }
        // Header: app icon + name + one-line description, so it is clear what this menu bar item is
        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let icon = NSApp.applicationIconImage.copy() as! NSImage; icon.size = NSSize(width: 32, height: 32)
        header.image = icon
        let title = NSMutableAttributedString(string: "runawake\n", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        title.append(NSAttributedString(string: T("動いている間だけ Mac を起こしておく", "Keeps your Mac awake only while things run"),
                                        attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        header.attributedTitle = title
        menu.addItem(header)
        menu.addItem(.separator())
        if paused {
            note(T("オフ: Mac は通常どおりスリープします", "Off: your Mac sleeps as usual"))
        } else if reasons.isEmpty {
            note(T("いまは何も動いていません", "Nothing is running"))
            note(T("コマンドや AI が動いている間だけ Mac を起こします", "Keeps your Mac awake only while commands or AI agents run"))
        } else {
            note(holding ? T("Mac を起こしています(\(reasons.count)件)", "Keeping your Mac awake (\(reasons.count))") : T("Mac を起こそうとしています", "Trying to keep your Mac awake"))
            for r in reasons { note("    " + r) }
        }
        if lowBattery {
            note(T("電池が \(batteryFloor)% を切ったため止めています(電源につなぐと再開します)", "Battery below \(batteryFloor)% — paused until you plug in"))
        }
        if overheated {
            note(T("Mac が熱くなったため休ませています(冷えたら再開します)", "Your Mac is hot — resting until it cools down"))
        }
        if lidMode && detector.capsomniaRunning {
            note(T("⚠ Capsomnia が動いているため「蓋を閉じても起こしておく」は効きません", "⚠ Capsomnia is running, so lid-closed mode has no effect"))
        }
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: paused ? T("オンにする", "Turn On") : T("オフにする(通常どおりスリープさせる)", "Turn Off (sleep as usual)"),
                                action: #selector(togglePause), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let lid = NSMenuItem(title: T("蓋を閉じても起こしておく", "Keep Awake with the Lid Closed"), action: #selector(toggleLid), keyEquivalent: "")
        lid.target = self
        lid.state = lidMode ? .on : .off
        menu.addItem(lid)
        let wn = NSMenuItem(title: T("蓋を開けたとき、閉じていた間のことを表示する", "Show a Summary When You Open the Lid"), action: #selector(toggleWakeNote), keyEquivalent: "")
        wn.target = self
        wn.state = wakeNoteEnabled ? .on : .off
        menu.addItem(wn)
        let heat = NSMenuItem(title: T("熱くなったら止める", "Stop When the Mac Gets Hot"), action: #selector(toggleHeatGuard), keyEquivalent: "")
        heat.target = self
        heat.state = heatGuardEnabled ? .on : .off
        menu.addItem(heat)
        let pulse = NSMenuItem(title: T("動いている間はアイコンを動かす", "Animate the Icon While Awake"), action: #selector(togglePulse), keyEquivalent: "")
        pulse.target = self
        pulse.state = pulseEnabled ? .on : .off
        menu.addItem(pulse)
        let pick = NSMenuItem(title: T("アイコン", "Icon"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for c in Critter.all {
            let it = NSMenuItem(title: c.name, action: #selector(pickCritter(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = c.id; it.image = c.idle; it.state = c.id == critter.id ? .on : .off
            sub.addItem(it)
        }
        pick.submenu = sub
        menu.addItem(pick)
        let ign = NSMenuItem(title: T("見張らないコマンドを編集…", "Edit Ignored Commands…"), action: #selector(openIgnore), keyEquivalent: "")
        ign.target = self
        menu.addItem(ign)
        menu.addItem(.separator())
        menu.addItem(withTitle: T("runawake を終了", "Quit runawake"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    @objc func togglePause() { paused.toggle(); tick() }
    @objc func pickCritter(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? String, forKey: "critter")
        animTimer?.invalidate(); animTimer = nil; animFrame = 0
        tick()
    }
    @objc func togglePulse() { pulseEnabled.toggle(); render() }
    @objc func toggleHeatGuard() { heatGuardEnabled.toggle(); tick() }
    @objc func toggleWakeNote() { wakeNoteEnabled.toggle(); render() }

    @objc func toggleLid() {
        if lidMode {
            lidMode = false; applyLid(); render(); return
        }
        guard Lid.available else {
            let a = NSAlert()
            a.messageText = T("蓋を閉じても起こしておくには、初回だけ設定が必要です", "Lid-closed mode needs a one-time setup")
            a.informativeText = Lid.setupHint + T("\n\n設定したら、もう一度このメニューを選んでください。", "\n\nAfter that, choose this menu item again.")
            a.addButton(withTitle: T("コマンドをコピー", "Copy Command")); a.addButton(withTitle: T("閉じる", "Close"))
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn {
                let cmd = Lid.setupHint.components(separatedBy: "\n").first { $0.hasPrefix("sudo ") } ?? ""
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string)
            }
            return
        }
        lidMode = true; logLine(T("蓋モード: オン", "Lid mode: on")); applyLid(); render()
    }

    @objc func openIgnore() {
        let dir = NSHomeDirectory() + "/.runawake"
        let path = dir + "/ignore"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            try? T("# ターミナルで動いていても Mac を起こさないコマンド名(1行1つ)。例: vim, ssh, top\n", "# Commands that should not keep your Mac awake, one per line. e.g. vim, ssh, top\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

if CommandLine.arguments.contains("--once") {
    // For testing: poll twice (CPU detection needs a delta), print the detection result, and exit
    let d = Detector()
    _ = d.scan(ignore: loadIgnore())
    Thread.sleep(forTimeInterval: pollSeconds)
    let r = merged(busyMarkedAgents() + d.scan(ignore: loadIgnore()))
    print(r.isEmpty ? "idle" : r.joined(separator: "\n"))
    exit(0)
}

let app = NSApplication.shared
// Place the icon near the right end of the menu bar (next to Control Center) on first launch, so it is not
// pushed under the notch when the menu bar is crowded. After that, wherever the user ⌘-drags it is remembered.
let positionKey = "NSStatusItem Preferred Position runawake"
if UserDefaults.standard.object(forKey: positionKey) == nil || UserDefaults.standard.bool(forKey: "positionReset") == false {
    UserDefaults.standard.set(1.0, forKey: positionKey)
    UserDefaults.standard.set(true, forKey: "positionReset")
}
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
