import Foundation
import JavaScriptCore
import GizmoCore

/// One plugin: its own JavaScriptCore VM and context, driven from its own
/// serial queue, so a slow or crashed plugin never blocks the bar or the
/// other plugins. Every call into JS goes through `queue`.
public final class PluginRuntime: @unchecked Sendable {
    public struct Hooks: Sendable {
        public var log: @Sendable (String, String) -> Void
        /// A provider the plugin uses, with its minimum refresh interval.
        public var use: @Sendable (String, Double) -> Void
        public var subscribe: @Sendable (String) -> Void
        public var emit: @Sendable (String, JSONValue) -> Void
        public var request: @Sendable (String) -> Void
        public var open: @Sendable (URL) -> Void
        /// The plugin asked to render again (timers, fetch results...).
        public var rerender: @Sendable () -> Void

        public init(log: @escaping @Sendable (String, String) -> Void, use: @escaping @Sendable (String, Double) -> Void,
                    subscribe: @escaping @Sendable (String) -> Void, emit: @escaping @Sendable (String, JSONValue) -> Void,
                    request: @escaping @Sendable (String) -> Void, open: @escaping @Sendable (URL) -> Void,
                    rerender: @escaping @Sendable () -> Void) {
            self.log = log; self.use = use; self.subscribe = subscribe; self.emit = emit
            self.request = request; self.open = open; self.rerender = rerender
        }
    }

    public let manifest: PluginManifest
    public let directory: URL
    private let hooks: Hooks
    private let queue: DispatchQueue
    private var vm: JSVirtualMachine!
    private var context: JSContext!
    private var timers: [Int: DispatchSourceTimer] = [:]
    private var storage: [String: String] = [:]
    private var storageDirty = false
    private var lastError: String?

    public init(directory: URL, manifest: PluginManifest, hooks: Hooks) {
        self.directory = directory
        self.manifest = manifest
        self.hooks = hooks
        queue = DispatchQueue(label: "gizmobar.plugin.\(manifest.id)", qos: .userInitiated)
    }

    deinit {
        for t in timers.values { t.cancel() }
    }

    // MARK: Lifecycle

    /// Evaluates the prelude and the bundle and calls `setup(ctx)`.
    /// Returns an error message on failure.
    public func load(config: JSONValue, theme: [String: String]) async -> String? {
        await onQueue { [self] in
            vm = JSVirtualMachine()
            context = JSContext(virtualMachine: vm)
            context.name = "gizmobar: \(manifest.id)"
            context.exceptionHandler = { [weak self] _, exc in
                let msg = exc?.toString() ?? "unknown error"
                let stack = exc?.objectForKeyedSubscript("stack")?.toString() ?? ""
                self?.lastError = msg
                self?.hooks.log("error", stack.isEmpty || stack == "undefined" ? msg : "\(msg)\n\(stack)")
            }
            ExecutionLimit.apply(to: context, seconds: 0.25)
            loadStorage()
            installHost()
            context.evaluateScript(Prelude.source)
            let entry = directory.appendingPathComponent(manifest.entry)
            guard let code = try? String(contentsOf: entry, encoding: .utf8) else {
                return "can't read \(manifest.entry); build the plugin first (npm run build)"
            }
            lastError = nil
            context.evaluateScript(code, withSourceURL: entry)
            if let e = lastError { return e }
            let configJSON = Self.json(config)
            let themeJSON = Self.json(JSONValue(encoding: theme))
            context.objectForKeyedSubscript("__setup")?.call(withArguments: [configJSON, themeJSON])
            return lastError
        }
    }

    public func unload() async {
        await onQueue { [self] in
            for t in timers.values { t.cancel() }
            timers = [:]
            saveStorage()
            context = nil
            vm = nil
        }
    }

    // MARK: Driving

    public func setProvider(_ name: String, _ value: JSONValue) async {
        let json = Self.json(value)
        await onQueue { [self] in _ = context?.objectForKeyedSubscript("__setProvider")?.call(withArguments: [name, json]) }
    }

    public func dispatch(topic: String, payload: JSONValue) async {
        let json = Self.json(payload)
        await onQueue { [self] in _ = context?.objectForKeyedSubscript("__dispatch")?.call(withArguments: [topic, json]) }
    }

    /// Renders the bar tree and times it.
    public func render() async -> (PluginNode, Double) {
        await onQueue { [self] in timed { context?.objectForKeyedSubscript("__render")?.call(withArguments: []) } }
    }

    public func renderPopover(_ callback: Int) async -> PluginNode {
        await onQueue { [self] in timed { context?.objectForKeyedSubscript("__renderPopover")?.call(withArguments: [callback]) }.0 }
    }

    public func invoke(_ callback: Int, _ arg: JSONValue = .null) async {
        let json = Self.json(arg)
        await onQueue { [self] in
            _ = context?.objectForKeyedSubscript("__invoke")?.call(withArguments: [callback, json])
            saveStorage()
        }
    }

    private func timed(_ body: () -> JSValue?) -> (PluginNode, Double) {
        lastError = nil
        let start = DispatchTime.now().uptimeNanoseconds
        let result = body()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        if let e = lastError { return (.error(e), ms) }
        guard let s = result?.toString(), let v = try? JSONValue(parsing: Data(s.utf8)) else { return (.error("render returned nothing"), ms) }
        return (PluginNode.parse(v), ms)
    }

    // MARK: Host functions

    private func installHost() {
        let host = JSValue(newObjectIn: context)!
        let m = manifest, hooks = self.hooks
        func set(_ name: String, _ block: Any) { host.setObject(block, forKeyedSubscript: name as NSString) }

        set("log", { (level: String, msg: String) in hooks.log(level, msg) } as @convention(block) (String, String) -> Void)
        set("use", { (name: String, every: Double) -> Bool in
            guard m.allows("provider:\(name)"), PluginProviders.spec(name) != nil else { return false }
            hooks.use(name, every)
            return true
        } as @convention(block) (String, Double) -> Bool)
        set("subscribe", { (topic: String) in hooks.subscribe(topic) } as @convention(block) (String) -> Void)
        set("emit", { (topic: String, json: String) in
            hooks.emit(topic, (try? JSONValue(parsing: Data(json.utf8))) ?? .null)
        } as @convention(block) (String, String) -> Void)
        set("request", { (name: String) in
            if m.allows("requests") { hooks.request(name) } else { hooks.log("error", "add \"requests\" to permissions to call ctx.request") }
        } as @convention(block) (String) -> Void)
        set("rerender", { hooks.rerender() } as @convention(block) () -> Void)
        set("open", { (s: String) in
            guard let url = URL(string: s), ["http", "https", "mailto"].contains(url.scheme ?? "") || url.isFileURL else { return }
            hooks.open(url)
        } as @convention(block) (String) -> Void)
        set("storageGet", { [weak self] (key: String) -> String? in self?.storage[key] } as @convention(block) (String) -> String?)
        set("storageSet", { [weak self] (key: String, json: String) in
            self?.storage[key] = json
            self?.storageDirty = true
        } as @convention(block) (String, String) -> Void)
        set("setTimer", { [weak self] (id: Int, ms: Double, repeating: Bool) in
            self?.startTimer(id, ms: ms, repeating: repeating)
        } as @convention(block) (Int, Double, Bool) -> Void)
        set("clearTimer", { [weak self] (id: Int) in self?.timers.removeValue(forKey: id)?.cancel() } as @convention(block) (Int) -> Void)
        set("fetch", { [weak self] (url: String, initJSON: String, id: Int) in
            self?.fetch(url, initJSON, id)
        } as @convention(block) (String, String, Int) -> Void)
        set("exec", { [weak self] (cmd: String, argsJSON: String, id: Int) in
            self?.exec(cmd, argsJSON, id)
        } as @convention(block) (String, String, Int) -> Void)
        context.setObject(host, forKeyedSubscript: "__host" as NSString)
    }

    private func startTimer(_ id: Int, ms: Double, repeating: Bool) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.milliseconds(Int(ms))
        t.schedule(deadline: .now() + interval, repeating: repeating ? interval : .never, leeway: .milliseconds(Int(max(ms * 0.1, 5))))
        t.setEventHandler { [weak self] in
            guard let self, let ctx = self.context else { return }
            if !repeating { self.timers[id] = nil }
            ctx.objectForKeyedSubscript("__fire")?.call(withArguments: [id])
            self.saveStorage()
            self.hooks.rerender()
        }
        timers[id]?.cancel()
        timers[id] = t
        t.resume()
    }

    private func reply(_ id: Int, ok: Bool, _ value: JSONValue) {
        let json = Self.json(value)
        queue.async { [weak self] in
            guard let self, let ctx = self.context else { return }
            ctx.objectForKeyedSubscript("__resolve")?.call(withArguments: [id, ok, json])
            self.hooks.rerender()
        }
    }

    private func fetch(_ urlString: String, _ initJSON: String, _ id: Int) {
        guard let url = URL(string: urlString), let host = url.host, url.scheme == "https" || url.scheme == "http" else {
            return reply(id, ok: false, .string("bad URL \(urlString)"))
        }
        guard manifest.allows("net:\(host)") else {
            return reply(id, ok: false, .string("add \"net:\(host)\" to permissions in plugin.json"))
        }
        let opts = (try? JSONValue(parsing: Data(initJSON.utf8))) ?? .object([:])
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = opts["method"]?.string ?? "GET"
        if case .object(let headers)? = opts["headers"] {
            for (k, v) in headers { if let s = v.string { req.setValue(s, forHTTPHeaderField: k) } }
        }
        if let body = opts["body"]?.string { req.httpBody = Data(body.utf8) }
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            if let error { return self?.reply(id, ok: false, .string(error.localizedDescription)) ?? () }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(decoding: (data ?? Data()).prefix(4 << 20), as: UTF8.self)
            self?.reply(id, ok: true, ["status": .number(Double(status)), "body": .string(body)])
        }.resume()
    }

    private func exec(_ cmd: String, _ argsJSON: String, _ id: Int) {
        guard manifest.allows("exec") else { return reply(id, ok: false, .string("add \"exec\" to permissions in plugin.json")) }
        let args = ((try? JSONValue(parsing: Data(argsJSON.utf8)))?.array ?? []).compactMap(\.string)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            if cmd.hasPrefix("/") {
                p.executableURL = URL(fileURLWithPath: cmd)
                p.arguments = args
            } else {
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = [cmd] + args
            }
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return self?.reply(id, ok: false, .string("\(error)")) ?? () }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            self?.reply(id, ok: true, ["code": .number(Double(p.terminationStatus)), "stdout": .string(String(decoding: data, as: UTF8.self))])
        }
    }

    // MARK: Storage

    private var storageFile: URL {
        GizmoPaths.stateDir.appendingPathComponent("plugins/\(manifest.id).json")
    }

    private func loadStorage() {
        guard let data = try? Data(contentsOf: storageFile),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        storage = dict
    }

    private func saveStorage() {
        guard storageDirty else { return }
        storageDirty = false
        try? FileManager.default.createDirectory(at: storageFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(storage).write(to: storageFile, options: .atomic)
    }

    // MARK: Helpers

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in queue.async { cont.resume(returning: body()) } }
    }

    static func json(_ v: JSONValue) -> String {
        (try? String(decoding: JSONEncoder().encode(v), as: UTF8.self)) ?? "null"
    }
}

/// Stops runaway scripts (an infinite loop in a render) after a time limit,
/// through JavaScriptCore's JSContextGroupSetExecutionTimeLimit, looked up
/// at runtime. Without it a stuck plugin still only blocks its own queue.
enum ExecutionLimit {
    private typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void

    static var available: Bool { dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") != nil }

    static func apply(to context: JSContext, seconds: Double) {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return }
        let set = unsafeBitCast(sym, to: SetLimit.self)
        set(JSContextGetGroup(context.jsGlobalContextRef), seconds, nil, nil)
    }
}
