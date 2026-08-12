import Flutter
import Darwin

public class FrappeSecurityPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "frappe_mobile_sdk/security",
            binaryMessenger: registrar.messenger()
        )
        let instance = FrappeSecurityPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if call.method == "getMonotonicMillis" {
            var ts = timespec()
            clock_gettime(CLOCK_MONOTONIC_RAW, &ts)
            let millis = Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000
            result(millis)
        } else {
            result(FlutterMethodNotImplemented)
        }
    }
}
