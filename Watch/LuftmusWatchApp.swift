import SwiftUI
import CoreMotion
import CoreBluetooth
import WatchKit

// Klockappen är "dum" med flit: den skickar bara råa rörelser (100 per sekund),
// knapptryck och kronan till datorn. All smart logik (armpekning, nyp = klick,
// fart, paus) ligger i datorns luftmus/watch.py, så den kan förbättras utan
// ominstallation.
//
// v3: Bluetooth LE DIREKT till datorn (ingen iPhone emellan, ~30 ms fördröjning).
// Wi-Fi (via iPhonen) finns kvar som reserv.

@main
struct LuftmusWatchApp: App {
    @StateObject private var streamer = Streamer()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(streamer)
        }
    }
}

// Datorns Bluetooth-tjänst (måste matcha luftmus/ble/Program.cs).
let serviceUUID = CBUUID(string: "AD7E")
let dataUUID = CBUUID(string: "0A1DE1D1-D9D7-47A1-8899-25832BD49174")
let statusUUID = CBUUID(string: "60153640-7609-44BA-9067-881D0AFB4FDD")

final class Streamer: NSObject, ObservableObject, URLSessionDelegate, WKExtendedRuntimeSessionDelegate,
                      CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var running = false
    @Published var status = "Av"
    @Published var link = ""          // "Bluetooth" / "Wi-Fi" / ""
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
    private var rows: [[Double]] = []      // för Wi-Fi (JSON)
    private var packed = Data()            // för Bluetooth (20 byte per mätning)
    private var packedCount = 0
    private var crownAcc = 0.0
    private var timer: Timer?
    private var inflight = false
    private var runtime: WKExtendedRuntimeSession?
    private var lastPhase = ""
    private var t0: TimeInterval = 0

    // Bluetooth
    private var central: CBCentralManager?
    private var pc: CBPeripheral?
    private var dataChar: CBCharacteristic?
    private var bleReady = false
    private var bleQueue: [Data] = []       // viktiga meddelanden (knapp, kalib.)

    // MARK: start/stopp
    func start() {
        guard motion.isDeviceMotionAvailable else { status = "Ingen rörelsesensor"; return }
        running = true
        status = "Söker datorn…"
        t0 = ProcessInfo.processInfo.systemUptime
        motionQueue.maxConcurrentOperationCount = 1
        motion.deviceMotionUpdateInterval = 1.0 / 100.0
        motion.startDeviceMotionUpdates(to: motionQueue) { [weak self] m, _ in
            guard let self = self, let m = m else { return }
            self.add(m)
        }
        central = CBCentralManager(delegate: self, queue: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
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
        if let pc = pc { central?.cancelPeripheralConnection(pc) }
        central = nil
        pc = nil
        dataChar = nil
        bleReady = false
        link = ""
        status = "Av"
    }

    // MARK: mätningar
    private func add(_ m: CMDeviceMotion) {
        let d = 180.0 / Double.pi
        let gx = m.rotationRate.x * d, gy = m.rotationRate.y * d, gz = m.rotationRate.z * d
        let ms = UInt16(truncatingIfNeeded: Int(((m.timestamp - t0) * 1000).rounded()))
        func i16(_ v: Double) -> Int16 { Int16(max(-32767, min(32767, v.rounded()))) }
        var bytes = Data(capacity: 20)
        func put16(_ v: UInt16) { bytes.append(UInt8(v & 0xff)); bytes.append(UInt8(v >> 8)) }
        put16(ms)
        for v in [gx * 10, gy * 10, gz * 10,
                  m.gravity.x * 10000, m.gravity.y * 10000, m.gravity.z * 10000,
                  m.userAcceleration.x * 2000, m.userAcceleration.y * 2000, m.userAcceleration.z * 2000] {
            put16(UInt16(bitPattern: i16(v)))
        }
        let row: [Double] = [m.timestamp, gx, gy, gz, m.gravity.x, m.gravity.y, m.gravity.z,
                             m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z]
        lock.lock()
        packed.append(bytes)
        packedCount += 1
        if packedCount > 100 {  // max 1 s kö
            packed.removeFirst(20)
            packedCount -= 1
        }
        rows.append(row)
        if rows.count > 100 { rows.removeFirst(rows.count - 100) }
        lock.unlock()
    }

    func crown(_ delta: Double) {
        lock.lock(); crownAcc += delta; lock.unlock()
    }

    // Knapp / kalibrering
    func send(_ msg: [String: Any]) {
        WKInterfaceDevice.current().play(.click)
        if bleReady {
            let t = msg["t"] as? String
            if t == "kal" {
                bleQueue.append(header(3))
            } else if t == "tap" {
                var d = header(2)
                d.append(UInt8((msg["a"] as? String) == "rclick" ? 2 : 1))
                bleQueue.append(d)
            }
            flush()
        } else {
            post(msg, important: true)
        }
    }

    private func header(_ type: UInt8) -> Data {
        let c = UInt32(code.filter(\.isNumber).prefix(6)) ?? 0
        return Data([type, UInt8(c & 0xff), UInt8((c >> 8) & 0xff), UInt8((c >> 16) & 0xff)])
    }

    private func flush() {
        if bleReady, let pc = pc, let ch = dataChar {
            flushBLE(pc, ch)
        } else {
            flushWiFi()
        }
    }

    // MARK: Bluetooth-sändning
    private func flushBLE(_ pc: CBPeripheral, _ ch: CBCharacteristic) {
        while !bleQueue.isEmpty {
            pc.writeValue(bleQueue.removeFirst(), for: ch, type: .withResponse)
        }
        lock.lock()
        let c = crownAcc
        crownAcc = 0
        lock.unlock()
        if c != 0 {
            var d = header(4)
            var f = Float(c)
            withUnsafeBytes(of: &f) { d.append(contentsOf: $0) }
            pc.writeValue(d, for: ch, type: .withResponse)
        }
        let maxLen = pc.maximumWriteValueLength(for: .withoutResponse)
        let perPacket = max(1, min(25, (maxLen - 5) / 20))
        while pc.canSendWriteWithoutResponse {
            lock.lock()
            let n = min(perPacket, packedCount)
            if n == 0 { lock.unlock(); break }
            let chunk = packed.prefix(n * 20)
            packed.removeFirst(n * 20)
            packedCount -= n
            rows.removeAll()
            lock.unlock()
            var d = header(1)
            d.append(UInt8(n))
            d.append(chunk)
            pc.writeValue(d, for: ch, type: .withoutResponse)
        }
    }

    // MARK: Wi-Fi-reserv
    private func flushWiFi() {
        if inflight { return }
        lock.lock()
        let r = rows
        rows.removeAll()
        packed.removeAll()
        packedCount = 0
        let c = crownAcc
        crownAcc = 0
        lock.unlock()
        if r.isEmpty && c == 0 { return }
        post(["t": "raw", "s": r, "c": c], important: false)
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
                if self.bleReady { return }
                if error != nil { self.status = "Når inte datorn"; self.link = ""; return }
                let httpCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if httpCode == 403 { self.status = "Fel kod"; return }
                if httpCode == 429 { self.status = "Vänta 30 s"; return }
                if let data = data { self.link = "Wi-Fi"; self.apply(data) }
            }
        }.resume()
    }

    // Status från datorn (JSON): s = text, p = läge, e = händelse
    private func apply(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let s = json["s"] as? String { status = s }
        if let p = json["p"] as? String, p != lastPhase {
            lastPhase = p
            WKInterfaceDevice.current().play(.directionUp)
        }
        if let e = json["e"] as? String, e == "nyp" {
            WKInterfaceDevice.current().play(.click)
        }
    }

    // MARK: CoreBluetooth
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn {
            c.scanForPeripherals(withServices: [serviceUUID], options: nil)
        } else if c.state == .unauthorized {
            status = "Tillåt Bluetooth för Luftmus"
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard pc == nil else { return }
        pc = p
        p.delegate = self
        c.stopScan()
        c.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([serviceUUID])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        restartScan()
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        restartScan()
    }

    private func restartScan() {
        pc = nil
        dataChar = nil
        bleReady = false
        if link == "Bluetooth" { link = "" }
        guard running, let c = central, c.state == .poweredOn else { return }
        c.scanForPeripherals(withServices: [serviceUUID], options: nil)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == serviceUUID }) else { return }
        p.discoverCharacteristics([dataUUID, statusUUID], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == dataUUID { dataChar = ch }
            if ch.uuid == statusUUID { p.setNotifyValue(true, for: ch) }
        }
        if dataChar != nil {
            bleReady = true
            link = "Bluetooth"
            status = "Ansluten 🔵"
            var d = header(5)
            d.append(UInt8(0))
            p.writeValue(d, for: dataChar!, type: .withResponse)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if ch.uuid == statusUUID, let v = ch.value { apply(v) }
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        flush()
    }

    // MARK: Wi-Fi-certifikat
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
                TextField("Kod", text: $s.code)
                TextField("Reserv: dator (ip:port)", text: $s.host)
                    .textContentType(.URL)
                    .font(.footnote)
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

// Körskärmen: sida 1 = EN enda stor KLICK-yta (så Apples AssistiveTouch-nyp
// alltid trycker rätt), sida 2 (svep åt vänster) = Höger, Kalib., Stopp.
struct RunView: View {
    @EnvironmentObject var s: Streamer
    @State private var crown = 0.0
    @State private var lastCrown = 0.0
    var body: some View {
        TabView {
            Button { s.send(["t": "tap", "a": "click"]) } label: {
                VStack(spacing: 4) {
                    Text(s.status)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                    Text(s.link.isEmpty ? "…" : (s.link == "Bluetooth" ? "🔵" : "📶 Wi-Fi"))
                        .font(.caption2)
                    Text("KLICK").font(.title2).bold()
                    Text("nyp = klick · svep ← mer")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .focusable(true)
            .digitalCrownRotation($crown, from: -1_000_000, through: 1_000_000, by: 0.1,
                                  sensitivity: .medium, isContinuous: true, isHapticFeedbackEnabled: false)
            .onChange(of: crown) { newValue in
                s.crown(newValue - lastCrown)
                lastCrown = newValue
            }

            VStack(spacing: 8) {
                Button("Högerklick") { s.send(["t": "tap", "a": "rclick"]) }
                Button("Kalibrera") { s.send(["t": "kal"]) }
                Button("Stopp") { s.stop() }.tint(.red)
            }
        }
        .tabViewStyle(.page)
    }
}
