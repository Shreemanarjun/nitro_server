import FlutterMacOS
import AppKit

public class SwiftNitroServerPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        NitroServerRegistry.register(NitroServerImpl())
    }
}
