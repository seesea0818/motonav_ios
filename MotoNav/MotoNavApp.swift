import SwiftUI
import Combine

// 圆屏只持有收藏快照和路线编号，坐标与规划仍由手机管理。
final class ScreenFavorites {
    static let shared = ScreenFavorites()
    private var revision = 0, offset = 0, token = 0, planRevision = -1
    private var snapshot: [Favorites.Place] = []
    private var routeIDs: [Int] = []
    private var timer: Timer?
    private var observation: AnyCancellable?
    private init() {
        observation = Favorites.shared.$places.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, BleLink.shared.isReady, BleLink.shared.verified else { return }
                self.publish(offset: self.offset)
            }
        }
    }
    func publish(offset requested: Int) {
        guard BleLink.shared.isReady, BleLink.shared.verified else { return }
        timer?.invalidate(); timer = nil; routeIDs = []
        snapshot = Favorites.shared.places; revision = revision == 65535 ? 1 : revision + 1
        offset = max(0, min(requested, snapshot.count == 0 ? 0 : ((snapshot.count - 1) / 4) * 4))
        let items = Array(snapshot.dropFirst(offset).prefix(4))
        BleLink.shared.sendOnce("#FV,\(revision),\(offset),\(items.count),\(snapshot.count)")
        let limit = TextBitmapBudget.bytes(maxWrite: BleLink.shared.maxWrite)
        for i in 0..<4 {
            TextImage.send(slot: 17+i, i < items.count ? items[i].name : "", maxW: 280, size: 23, minSize: 16, byteLimit: limit)
        }
    }
    func receive(_ parts: [String]) {
        guard parts.count >= 3, BleLink.shared.isReady, BleLink.shared.verified else { return }
        let navi = NaviBridge.shared
        switch parts[2] {
        case "LIST": publish(offset: parts.count > 3 ? (Int(parts[3]) ?? 0) : 0)
        case "PLAN":
            guard parts.count >= 5, let rev=Int(parts[3]), let index=Int(parts[4]), rev==revision,
                  snapshot.indices.contains(index), Favorites.shared.places.contains(where: { $0.id == snapshot[index].id }),
                  !Settings.shared.amapKeyInUse.isEmpty, BleLink.shared.maxWrite >= 40 else { BleLink.shared.sendOnce("#FE"); return }
            timer?.invalidate(); routeIDs=[]; token = token == 65535 ? 1 : token + 1
            let place=snapshot[index]
            if WebMotorSession.shared.running { WebMotorSession.shared.stop() }
            if navi.navigating { navi.stop() }
            navi.plan(toLat: place.lat, lng: place.lng)
            planRevision=navi.screenPlanRevision
            let expected=token, started=Date()
            timer=Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
                guard let self=self, self.token==expected, BleLink.shared.isReady else { timer.invalidate(); return }
                guard navi.screenPlanRevision==self.planRevision else { BleLink.shared.sendOnce("#FE"); timer.invalidate(); self.timer=nil; return }
                if navi.routeReady && !navi.routeOptions.isEmpty {
                    let options=Array(navi.routeOptions.prefix(3)); self.routeIDs=options.map { $0.id }
                    BleLink.shared.sendOnce("#FR,\(expected),\(options.count)")
                    for (i, route) in options.enumerated() {
                        let tag = route.label.contains("推荐") ? 1 : route.label.contains("常规") ? 2 : route.label.contains("少灯") ? 3 : 0
                        BleLink.shared.sendOnce("#F\(i),\(expected),\(route.timeS),\(route.length),\(route.lights),\(tag)")
                    }
                    timer.invalidate(); self.timer=nil
                } else if navi.planFailed || Date().timeIntervalSince(started)>25 {
                    BleLink.shared.sendOnce("#FE"); timer.invalidate(); self.timer=nil
                }
            }
        case "GO":
            guard parts.count >= 5, let t=Int(parts[3]), let index=Int(parts[4]), t==token,
                  routeIDs.indices.contains(index), navi.routeReady, !navi.navigating,
                  navi.screenPlanRevision==planRevision, navi.routeOptions.contains(where: { $0.id==routeIDs[index] }) else { BleLink.shared.sendOnce("#FE"); return }
            guard navi.select(routeID: routeIDs[index]) else { BleLink.shared.sendOnce("#FE"); return }
            navi.start(emulate: false)
            BleLink.shared.sendOnce(navi.navigating ? "#FG" : "#FE")
            routeIDs=[]
        default: break
        }
    }
}

/// 版本：跟随 App 版本（见 Config.swift）
///
/// 高德导航界面（AMapNaviDriveView）创建时会调用 UIApplication.shared.delegate.window 判断是不是刘海屏。
/// SwiftUI 默认的 AppDelegate 没有 window，会直接崩溃（iOS v0.1.1 点“开始导航”就闪退的原因），
/// 所以这里补一个 AppDelegate，window 返回当前显示的窗口。
final class AppDelegate: NSObject, UIApplicationDelegate {
    var window: UIWindow? {
        get {
            let wins = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
            return wins.first { $0.isKeyWindow } ?? wins.first
        }
        set {}
    }
}

@main
struct MotoNavApp: App {
    @AppStorage("ui_appearance") private var appearance=0
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // 高德：key + 隐私合规声明（高德要求在用任何功能前调用；自己用的 App，直接设为已同意）
        AMapServices.shared().apiKey = Settings.shared.amapKeyInUse     // 用户在 App 里填的（iOS v0.7 起没有内置 key；没填时是空的）
        AMapServices.shared().enableHTTPS = true
        AMapNaviManagerConfig.shared().updatePrivacyShow(.didShow, privacyInfo: .didContain)
        AMapNaviManagerConfig.shared().updatePrivacyAgree(.didAgree)
        AMapSearchAPI.updatePrivacyShow(.didShow, privacyInfo: .didContain)
        AMapSearchAPI.updatePrivacyAgree(.didAgree)
        MAMapView.updatePrivacyShow(.didShow, privacyInfo: .didContain)
        MAMapView.updatePrivacyAgree(.didAgree)

        // 圆屏发来的通知
        BleLink.shared.onNotify = { msg in
            let p = msg.split(separator: ",").map(String.init)
            if p.count >= 3, p[0] == "T", p[1] == "F" { ScreenFavorites.shared.receive(p); return }
            if p.first == "BOOT", p.count >= 2, let id = Int(p[1]) { Settings.shared.bootReply(id); return }
            if p.count >= 3, p[0] == "T", p[1] == "CR" {
                if p[2] == "START" {
                    guard !Settings.shared.amapKeyInUse.isEmpty else { BleLink.shared.sendOnce("#CR,KEY"); return }
                    if NaviBridge.shared.startCruise() != nil { BleLink.shared.sendOnce("#CR,BUSY") }
                } else if p[2] == "STOP" {
                    if NaviBridge.shared.cruising { NaviBridge.shared.stopCruise() }
                    else { BleLink.shared.sendOnce("#CR,IDLE") }
                }
                return
            }
            if p.count >= 3, p[0] == "T", p[1] == "M" { MusicBridge.shared.handle(p[2]); return }
            if p.first == "T", p.count >= 2 {
                switch p[1] {
                case "W": Weather.shared.request()                    // 滑到了天气页
                case "A": break                                       // 按住接电话：iOS 不允许 App 接电话
                default: break
                }
            }
        }
        BleLink.shared.connect()
        LocationService.shared.start()
        Settings.shared.startDayNight()                 // 夜间配色、亮度按日出日落自动切换（每分钟检查）
        NaviBridge.shared.attach()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(AmapCaptureSurface().frame(width: 1, height: 1))
                .preferredColorScheme(AppearanceMode(rawValue:appearance)?.scheme)
                .onReceive(NotificationCenter.default.publisher(for:UIApplication.willResignActiveNotification)){_ in
                    MapFeeder.shared.setRenderingAvailable(false)
                }
                .onReceive(NotificationCenter.default.publisher(for:UIApplication.didBecomeActiveNotification)){_ in
                    MapFeeder.shared.setRenderingAvailable(true)
                    BleLink.shared.syncPhoneClock(force:true)
                    MusicBridge.shared.pollMetadata(force:true)
                }
        }
    }
}
