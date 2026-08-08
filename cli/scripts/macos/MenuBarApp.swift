// 9Router menu bar app — thin control plane for the local 9router gateway.
//
// Lifecycle contract:
//   - App launch → service auto-starts (dashboard opens once ready).
//   - App quit (any path: Quit button, Cmd+Q, system terminate) → the gateway
//     is fully stopped: launcher wrappers + standalone server + port owner.
//     This holds whether the gateway was started by the App or by the CLI
//     (model-driven path) — the App is the primary human control plane.
//   - CLI stays a supported control path for models/automation, but a gateway
//     it started is still owned by the App for shutdown purposes.
//
// Build: scripts/macos/build-app.sh (no Xcode project needed).

import AppKit
import SwiftUI
import Darwin

let kPort = 20128
let kHost = "127.0.0.1"
let kDashboardURL = "http://127.0.0.1:\(kPort)/dashboard"

/// Precise pkill patterns covering every 9router gateway process shape:
/// App-spawned launcher wrapper, standalone Next server, global CLI tray
/// wrapper (model-driven). Deliberately NOT matching: the sync daemon
/// (`9router config receive`) and the menu bar App itself (`.../MacOS/9Router`).
let kServicePkillPatterns = [
    "9router/cli.js --no-tray",      // App-spawned launcher wrapper
    "/9router/app/custom-server.js", // standalone Next server
    "/9router/app/server.js",        // standalone server (older layout)
    "9router --tray",                // global CLI tray wrapper (model-driven)
]

struct Status {
    var running: Bool = false
    var health: String = "checking…"
}

final class RouterController: NSObject, ObservableObject {
    @Published var status = Status()
    private var child: Process?
    private var timer: Timer?

    private var resourcesDir: URL {
        Bundle.main.resourceURL!
    }
    private var nodeBin: URL {
        resourcesDir.appendingPathComponent("node/bin/node")
    }
    private var cliJs: URL {
        resourcesDir.appendingPathComponent("9router/cli.js")
    }

    override init() {
        super.init()
        // The gateway must die with the App, whatever the exit path
        // (Quit button, Cmd+Q, logout/shutdown).
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification, object: nil)
        // Poll health every 5s so the menu reflects reality.
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refreshHealth()
        }
        refreshHealth()
        // Launch behaviour: make sure the service is up, then open the dashboard.
        // Wait for the first health poll so we don't blindly restart a running gateway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.launchAndOpenDashboard()
        }
    }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func appWillTerminate() {
        stop()
    }

    // MARK: - Synchronous process helpers

    /// Runs a command synchronously and returns trimmed stdout (or nil on failure).
    @discardableResult
    private func runSync(_ executable: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out?.isEmpty == true ? nil : out
    }

    private func pkill(_ pattern: String) {
        runSync("/usr/bin/pkill", ["-f", pattern])
    }

    /// PID of whatever currently listens on the gateway port (nil = free).
    private func portOwnerPid() -> Int? {
        guard let out = runSync("/usr/sbin/lsof", ["-ti:\(kPort)"]) else { return nil }
        return out.split(separator: "\n").first.flatMap { Int($0) }
    }

    /// Stops every 9router gateway process, then force-frees the port.
    /// Idempotent — safe to call from both Stop and quit paths.
    private func killAllServiceProcesses() {
        for pattern in kServicePkillPatterns {
            pkill(pattern)
        }
        // Give launcher wrappers time to run their graceful cleanup
        // (they SIGKILL their detached server themselves).
        Thread.sleep(forTimeInterval: 0.8)
        if let pid = portOwnerPid() {
            kill(pid_t(pid), SIGKILL)
        }
    }

    // MARK: - Health

    func refreshHealth() {
        let url = URL(string: "http://\(kHost):\(kPort)/v1/models")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                guard let self else { return }
                if let error = error {
                    self.status = Status(running: false, health: "stopped (\(error.localizedDescription.prefix(12)))")
                } else if (200..<500).contains(code) {
                    let models = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["data"] as? [Any] ?? []
                    self.status = Status(running: true, health: "running · \(models.count) models")
                } else {
                    self.status = Status(running: false, health: "error \(code)")
                }
            }
        }.resume()
    }

    // MARK: - Control

    /// Ensure the gateway is running, then open the dashboard.
    func launchAndOpenDashboard() {
        if status.running {
            openDashboard()
            return
        }
        start()
        // Wait until /v1/models answers, then open the dashboard (boot can take ~60s).
        var attempts = 0
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] timer in
            attempts += 1
            guard let self else { timer.invalidate(); return }
            self.refreshHealth()
            if self.status.running || attempts > 40 {
                timer.invalidate()
                if self.status.running { self.openDashboard() }
            }
        }
    }

    func start() {
        // Real state wins over bookkeeping: if something already answers on the
        // port (our child or an externally started gateway), that IS running.
        if portOwnerPid() != nil {
            refreshHealth()
            return
        }
        // Clear a stale child reference: dead wrapper → forget it;
        // wrapper alive but no server → terminate and rebuild.
        if let c = child {
            if c.isRunning { c.terminate() }
            child = nil
        }
        // Free the port and any leftover gateway processes before claiming it.
        killAllServiceProcesses()

        guard FileManager.default.fileExists(atPath: nodeBin.path),
              FileManager.default.fileExists(atPath: cliJs.path) else {
            status = Status(running: false, health: "bundled runtime missing")
            return
        }
        let proc = Process()
        proc.executableURL = nodeBin
        proc.arguments = [cliJs.path, "--no-tray", "--skip-update", "--host", kHost, "--port", String(kPort)]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.child = nil
                self?.refreshHealth()
            }
        }
        do {
            try proc.run()
            child = proc
            status = Status(running: false, health: "starting…")
            // First boot of the Next.js server can take ~60s; poll a bit faster.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.refreshHealth()
            }
        } catch {
            status = Status(running: false, health: "start failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        // Kill whatever listens on the port first (covers stale server children),
        // then terminate the CLI parent. Idempotent: also shuts down a gateway
        // that was started by the CLI (model-driven path).
        killAllServiceProcesses()
        if let c = child {
            if c.isRunning { c.terminate() }
            child = nil
        }
        status = Status(running: false, health: "stopped")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshHealth()
        }
    }

    func openDashboard() {
        NSWorkspace.shared.open(URL(string: kDashboardURL)!)
    }

    func openConfigDir() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".9router")
        NSWorkspace.shared.open(dir)
    }
}

@main
struct NineRouterApp: App {
    @StateObject private var controller = RouterController()

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle()
                        .fill(controller.status.running ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(controller.status.running ? "9Router" : "9Router")
                        .fontWeight(.semibold)
                    Spacer()
                }
                Text(controller.status.health)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Divider()

                Button(controller.status.running ? "Stop" : "Start") {
                    controller.status.running ? controller.stop() : controller.start()
                }
                .disabled(!controller.status.running && controller.status.health == "starting…")

                Button("Open Dashboard") { controller.openDashboard() }
                    .disabled(!controller.status.running)

                Button("Open Config Dir") { controller.openConfigDir() }

                Divider()

                Button("Quit") {
                    controller.stop()
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(8)
            .frame(width: 220)
        } label: {
            if let img = NSImage(named: "menubar") ?? loadMenubarImage() {
                Image(nsImage: img)
            } else {
                Image(systemName: "network")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Load the bundled tray icon (menubar.png in Resources).
private func loadMenubarImage() -> NSImage? {
    guard let url = Bundle.main.resourceURL?
        .appendingPathComponent("menubar.png") else { return nil }
    let img = NSImage(contentsOf: url)
    img?.size = NSSize(width: 18, height: 18)
    return img
}
