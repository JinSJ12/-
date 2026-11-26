import UIKit

/// 화면 방향을 바꿉니다. 평소에는 세로, 자막 보기에서는 가로입니다.
@MainActor
enum Orientation {
    private(set) static var mask: UIInterfaceOrientationMask = .portrait

    static func set(_ newMask: UIInterfaceOrientationMask) {
        mask = newMask
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: newMask)) { error in
                print("화면 방향 변경 실패: \(error.localizedDescription)")
            }
        }
    }
}

/// 앱을 보고 있는 동안 화면이 자동으로 꺼지지 않게 합니다.
@MainActor
enum ScreenAwake {
    static func enable() {
        // 이미 켜진 값이면 반영되지 않을 수 있어, 한 번 끄고 다시 켭니다.
        UIApplication.shared.isIdleTimerDisabled = false
        UIApplication.shared.isIdleTimerDisabled = true
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Orientation.mask
    }
}
