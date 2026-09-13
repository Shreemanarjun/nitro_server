import Foundation

/// Native implementation of HybridNitroServerProtocol on macOS.
public class NitroServerImpl: NSObject, HybridNitroServerProtocol {

    public func add(a: Double, b: Double) -> Double {
        return a + b
    }

    public func getGreeting(name: String) async throws -> String {
        return "Hello, \(name) from macOS!"
    }
}
