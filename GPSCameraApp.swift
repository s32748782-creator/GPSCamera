// 定位相機（原生 iOS App）
// 原生相機畫質，取景即時顯示 緯度 / 經度 / 時間，GPS 有數值才能拍，
// 畫面固定直向、轉手機只轉文字，拍完自動存進「照片」並附上 GPS 位置

import SwiftUI
import AVFoundation
import CoreLocation
import CoreMotion
import Photos

// ===== 可以自己改的設定 =====
enum Config {
    static let fontRatio: CGFloat = 0.05      // 字體大小：照片短邊的比例
    static let showTime = false               // true = 時間顯示到「時:分」
    static let color = UIColor(red: 0xE8 / 255.0, green: 0x40 / 255.0, blue: 0x2F / 255.0, alpha: 1)
    static let maxAccuracy: Double = 0        // 誤差幾公尺內才能拍（0 = 不限制）
    static let smoothSeconds: Double = 5      // GPS 用最近幾秒做加權平均
}
// ===========================

@main
struct GPSCameraApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .statusBarHidden(true)
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - 浮水印文字

func watermarkLines(_ c: CLLocationCoordinate2D?, date: Date = Date()) -> [String] {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = Config.showTime ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
    let lat = c.map { String(format: "%.6f", $0.latitude) } ?? "—"
    let lng = c.map { String(format: "%.6f", $0.longitude) } ?? "—"
    return ["緯度:\(lat)", "經度:\(lng)", "時間:\(f.string(from: date))"]
}

// MARK: - GPS（持續更新＋加權平均）

final class LocationModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: CLLocationCoordinate2D?
    @Published var accuracy: Double = 0
    @Published var denied = false
    private(set) var lastLocation: CLLocation?
    private let manager = CLLocationManager()
    private var samples: [CLLocation] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .other
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .denied, .restricted:
            denied = true
        case .authorizedWhenInUse, .authorizedAlways:
            denied = false
            m.startUpdatingLocation()
        default:
            break
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        for l in locs where l.horizontalAccuracy >= 0 {
            // 位置明顯改變 = 正在移動，重新計算
            if let cur = lastLocation,
               l.distance(from: cur) > l.horizontalAccuracy + cur.horizontalAccuracy + 5 {
                samples.removeAll()
            }
            samples.append(l)
        }
        let now = Date()
        samples = samples.filter { now.timeIntervalSince($0.timestamp) < Config.smoothSeconds }
        guard let best = samples.map({ $0.horizontalAccuracy }).min() else { return }

        var w = 0.0, la = 0.0, lo = 0.0
        for s in samples where s.horizontalAccuracy <= best * 2 {
            let wt = 1.0 / max(s.horizontalAccuracy * s.horizontalAccuracy, 1)
            w += wt
            la += s.coordinate.latitude * wt
            lo += s.coordinate.longitude * wt
        }
        guard w > 0 else { return }
        let c = CLLocationCoordinate2D(latitude: la / w, longitude: lo / w)
        let last = samples.last
        lastLocation = CLLocation(coordinate: c,
                                  altitude: last?.altitude ?? 0,
                                  horizontalAccuracy: best,
                                  verticalAccuracy: last?.verticalAccuracy ?? -1,
                                  timestamp: now)
        coordinate = c
        accuracy = best
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}

// MARK: - 方向偵測（畫面固定直向，只轉文字）

final class OrientationModel: ObservableObject {
    /// 文字要轉幾度：0 = 直拿，90 = 手機往左轉橫，-90 = 往右轉橫
    @Published var rotation: Double = 0
    private let motion = CMMotionManager()

    init() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self, let g = m?.gravity else { return }
            var r = self.rotation
            if g.y < -0.6 && abs(g.y) > abs(g.x) { r = 0 }
            else if g.x < -0.6 && abs(g.x) > abs(g.y) { r = 90 }
            else if g.x > 0.6 && abs(g.x) > abs(g.y) { r = -90 }
            if r != self.rotation { self.rotation = r }
        }
    }
}

// MARK: - 相機

final class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    @Published var ready = false
    @Published var savedCount = 0
    @Published var message: String?

    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "camera.session")
    private let lock = NSLock()
    private var pending: [Int64: Shot] = [:]

    struct Shot {
        let rotation: Double
        let location: CLLocation
        let lines: [String]
    }

    func start() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else {
                DispatchQueue.main.async { self.message = "請到「設定」允許相機" }
                return
            }
            self.queue.async { self.configure() }
        }
    }

    private func configure() {
        guard !session.isRunning else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.message = "相機無法啟動" }
            return
        }
        session.addInput(input)
        session.addOutput(output)
        output.maxPhotoQualityPrioritization = .balanced
        session.commitConfiguration()
        session.startRunning()
        DispatchQueue.main.async { self.ready = true }
    }

    func capture(rotation: Double, location: CLLocation, lines: [String]) {
        queue.async {
            if let conn = self.output.connection(with: .video) {
                if #available(iOS 17.0, *) {
                    if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
                } else if conn.isVideoOrientationSupported {
                    conn.videoOrientation = .portrait
                }
            }
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .balanced
            self.lock.lock()
            self.pending[settings.uniqueID] = Shot(rotation: rotation, location: location, lines: lines)
            self.lock.unlock()
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        lock.lock()
        let shot = pending.removeValue(forKey: photo.resolvedSettings.uniqueID)
        lock.unlock()
        guard error == nil, let shot,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let final = Watermark.render(image: image, rotation: shot.rotation, lines: shot.lines)
            guard let jpeg = final.jpegData(compressionQuality: 0.92) else { return }
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: jpeg, options: nil)
                req.location = shot.location
                req.creationDate = Date()
            }) { ok, _ in
                DispatchQueue.main.async {
                    if ok { self.savedCount += 1 }
                    else { self.message = "存檔失敗：請到「設定」允許加入照片" }
                }
            }
        }
    }
}

// MARK: - 把浮水印畫進照片

enum Watermark {
    static func render(image: UIImage, rotation: Double, lines: [String]) -> UIImage {
        let w = image.size.width, h = image.size.height
        let rotated = rotation != 0
        let size = rotated ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true

        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let c = ctx.cgContext
            c.saveGState()
            if rotation == 90 {          // 手機往左轉：影像逆時針轉正
                c.translateBy(x: 0, y: size.height)
                c.rotate(by: -.pi / 2)
            } else if rotation == -90 {  // 手機往右轉：影像順時針轉正
                c.translateBy(x: size.width, y: 0)
                c.rotate(by: .pi / 2)
            }
            image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
            c.restoreGState()

            let fs = min(size.width, size.height) * Config.fontRatio
            let font = UIFont.systemFont(ofSize: fs, weight: .bold)
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.25)
            shadow.shadowBlurRadius = fs * 0.08
            shadow.shadowOffset = .zero
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: Config.color, .shadow: shadow
            ]
            let lh = fs * 1.22
            let x = fs * 0.15
            let lastBaseline = size.height - fs * 0.35
            for (i, line) in lines.enumerated() {
                let baseline = lastBaseline - CGFloat(lines.count - 1 - i) * lh
                (line as NSString).draw(at: CGPoint(x: x, y: baseline - font.ascender), withAttributes: attrs)
            }
        }
    }
}

// MARK: - 取景畫面

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.backgroundColor = .black
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

// MARK: - 主畫面

struct ContentView: View {
    @StateObject private var camera = CameraModel()
    @StateObject private var location = LocationModel()
    @StateObject private var orient = OrientationModel()
    @State private var now = Date()
    @State private var flash = false
    @State private var showToast = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var canShoot: Bool {
        camera.ready && location.coordinate != nil &&
        (Config.maxAccuracy <= 0 || location.accuracy <= Config.maxAccuracy)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = w * 4 / 3
            VStack(spacing: 0) {
                topBar.frame(height: 50)
                ZStack {
                    CameraPreview(session: camera.session)
                    overlay(width: w, height: h)
                    Color.white.opacity(flash ? 0.8 : 0).allowsHitTesting(false)
                }
                .frame(width: w, height: h)
                .clipped()
                Spacer(minLength: 0)
                bottomBar
                Spacer(minLength: 0)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { camera.start() }
        .onReceive(timer) { now = $0 }
        .onChange(of: camera.savedCount) { _ in
            showToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { showToast = false }
        }
        .animation(.easeInOut(duration: 0.25), value: orient.rotation)
        .animation(.easeInOut(duration: 0.2), value: showToast)
    }

    // 取景畫面上的紅字：永遠在「你看過去的」左下角
    private func overlay(width w: CGFloat, height h: CGFloat) -> some View {
        let rotated = orient.rotation != 0
        let fs = min(w, h) * Config.fontRatio
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(watermarkLines(location.coordinate, date: now), id: \.self) { Text($0) }
        }
        .font(.system(size: fs, weight: .bold))
        .foregroundColor(Color(uiColor: Config.color))
        .shadow(color: .black.opacity(0.25), radius: fs * 0.08)
        .padding(.leading, fs * 0.15)
        .padding(.bottom, fs * 0.1)
        .frame(width: rotated ? h : w, height: rotated ? w : h, alignment: .bottomLeading)
        .rotationEffect(.degrees(orient.rotation))
        .frame(width: w, height: h)
        .allowsHitTesting(false)
    }

    private var topBar: some View {
        ZStack {
            if let msg = camera.message {
                capsule(Text(msg).foregroundColor(.red))
            } else if showToast {
                capsule(Text("已存到照片 ✅（\(camera.savedCount) 張）").foregroundColor(.white))
                    .rotationEffect(.degrees(orient.rotation))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var bottomBar: some View {
        HStack {
            Text(camera.savedCount > 0 ? "\(camera.savedCount) 張" : "")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .rotationEffect(.degrees(orient.rotation))
                .frame(width: 100)
            Spacer()
            Button(action: shoot) {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 4).frame(width: 76, height: 76)
                    Circle().fill(Color.white).frame(width: 62, height: 62)
                }
            }
            .disabled(!canShoot)
            .opacity(canShoot ? 1 : 0.3)
            Spacer()
            gpsPill
                .rotationEffect(.degrees(orient.rotation))
                .frame(width: 100)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
    }

    private var gpsPill: some View {
        let info: (String, String, Color) = {
            if location.denied { return ("定位", "被拒絕", .red) }
            guard location.coordinate != nil else { return ("等待", "GPS…", .yellow) }
            let a = Int(location.accuracy.rounded())
            if a <= 10 { return ("±\(a)m", "精準", .green) }
            if a <= 30 { return ("±\(a)m", "普通", .yellow) }
            return ("±\(a)m", "偏差大", .red)
        }()
        return VStack(spacing: 2) {
            Text("📍 " + info.0)
            Text(info.1)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(info.2)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.2)))
    }

    private func capsule(_ t: Text) -> some View {
        t.font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color(white: 0.2)))
    }

    private func shoot() {
        guard canShoot, let loc = location.lastLocation else { return }
        camera.capture(rotation: orient.rotation, location: loc, lines: watermarkLines(loc.coordinate, date: Date()))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeOut(duration: 0.05)) { flash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeIn(duration: 0.25)) { flash = false }
        }
    }
}
