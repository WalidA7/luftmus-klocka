import SwiftUI
import CoreMotion
import WatchKit

// Klockappen är "dum" med flit: den skickar bara råa rörelser, tryck och
// kronan till datorn. All smart logik (kalibrering, fart, utjämning, paus)
// ligger i datorns luftmus/watch.py, så den kan förbättras utan ominstallation.

@main
struct LuftmusWatchApp: App {
    @StateObject private var streamer = Streamer()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(streamer)
        }
    }
}

final class Streamer: NSObject, ObservableObject, URLSessionDelegate, WKExtendedRuntimeSessionDelegate {
    @Published var running = false
    @Published var status = "Av"
    @Published var host: String = UserDefaults.standard.string(forKey: "host") ?? "192.168.0.59:8443" {
        didSet { UserDefaults.standard.set(host, forKey: "host") }
    }
    @Published var code: String = UserDefaults.standard.string(forKey: "code") ?? "" {
        didSet { UserDefaults.standard.set(code, forKey: "code") }
    }

    private let motion = CMMotionManager()
    private let motionQueue = OperationQueue()
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3
        c.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()
    private let lock = NSLock()
    private var buffer: [[Double]] = []
    private var crownAcc = 0.0
    private var timer: Timer?
    private var inflight = false
    private var runtime: WKExtendedRuntimeSession?
    private var lastPhase = ""

    func start() {
        guard motion.isDeviceMotionAvailable else { status = "Ingen rörelsesensor"; return }
        running = true
        status = "Ansluter…"
        motionQueue.maxConcurrentOperationCount = 1
        motion.deviceMotionUpdateInterval = 1.0 / 50.0
        motion.startDeviceMotionUpdates(to: motionQueue) { [weak self] m, _ in
            guard let self = self, let m = m else { return }
            let d = 180.0 / Double.pi
            let row: [Double] = [
                m.timestamp,
                m.rotationRate.x * d, m.rotationRate.y * d, m.rotationRate.z * d,
                m.gravity.x, m.gravity.y, m.gravity.z,
                m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z,
            ]
            self.lock.lock()
            self.buffer.append(row)
            if self.buffer.count > 50 { self.buffer.removeFirst(self.buffer.count - 50) }
            self.lock.unlock()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            self?.flush()
        }
        let rt = WKExtendedRuntimeSession()
        rt.delegate = self
        rt.start()
        runtime = rt
    }

    func stop() {
        running = false
        motion.stopDeviceMotionUpdates()
        timer?.invalidate()
        timer = nil
        runtime?.invalidate()
        runtime = nil
        status = "Av"
    }

    func crown(_ delta: Double) {
        lock.lock(); crownAcc += delta; lock.unlock()
    }

    func send(_ msg: [String: Any]) {
        WKInterfaceDevice.current().play(.click)
        post(msg, important: true)
    }

    private func flush() {
        if inflight { return }
        lock.lock()
        let rows = buffer
        buffer.removeAll()
        let c = crownAcc
        crownAcc = 0
        lock.unlock()
        if rows.isEmpty && c == 0 { return }
        post(["t": "raw", "s": rows, "c": c], important: false)
    }

    private func post(_ msg: [String: Any], important: Bool) {
        var body = msg
        body["code"] = code
        guard let url = URL(string: "https://\(host)/msg"),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            status = "Fel adress"
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !important { inflight = true }
        session.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if !important { self.inflight = false }
                if error != nil { self.status = "Når inte datorn"; return }
                let httpCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if httpCode == 403 { self.status = "Fel kod"; return }
                if httpCode == 429 { self.status = "Vänta 30 s"; return }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                if let s = json["s"] as? String { self.status = s }
                if let p = json["p"] as? String, p != self.lastPhase {
                    self.lastPhase = p
                    WKInterfaceDevice.current().play(.directionUp)
                }
            }
        }.resume()
    }

    // Datorn har ett eget certifikat (bara på ditt Wi-Fi), så vi litar på det.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}
    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}
    func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                error: Error?) {}
}

struct ContentView: View {
    @EnvironmentObject var s: Streamer
    var body: some View {
        if s.running { RunView() } else { SetupView() }
    }
}

struct SetupView: View {
    @EnvironmentObject var s: Streamer
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("😎 Luftmus").font(.headline)
                TextField("Dator (ip:port)", text: $s.host)
                    .textContentType(.URL)
                TextField("Kod", text: $s.code)
                Button("Starta") { s.start() }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(s.code.isEmpty)
                if s.status != "Av" {
                    Text(s.status).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct RunView: View {
    @EnvironmentObject var s: Streamer
    @State private var crown = 0.0
    @State private var lastCrown = 0.0
    var body: some View {
        VStack(spacing: 6) {
            Text(s.status)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
            Button { s.send(["t": "tap", "a": "click"]) } label: {
                Text("KLICK").font(.title3).bold().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            HStack(spacing: 6) {
                Button("Höger") { s.send(["t": "tap", "a": "rclick"]) }
                Button("Kalib.") { s.send(["t": "kal"]) }
                Button("Stopp") { s.stop() }.tint(.red)
            }
            .font(.caption2)
        }
        .focusable(true)
        .digitalCrownRotation($crown, from: -1_000_000, through: 1_000_000, by: 0.1,
                              sensitivity: .medium, isContinuous: true, isHapticFeedbackEnabled: false)
        .onChange(of: crown) { newValue in
            s.crown(newValue - lastCrown)
            lastCrown = newValue
        }
    }
}
