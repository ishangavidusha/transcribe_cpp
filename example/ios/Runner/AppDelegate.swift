import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Keeps the screen on while listening or downloading. See screen.dart.
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "Screen")
    else { return }
    FlutterMethodChannel(
      name: "transcribe_cpp_example/screen",
      binaryMessenger: registrar.messenger()
    ).setMethodCallHandler { call, result in
      guard call.method == "keepOn", let on = call.arguments as? Bool else {
        result(FlutterMethodNotImplemented)
        return
      }
      UIApplication.shared.isIdleTimerDisabled = on
      result(nil)
    }
  }
}
