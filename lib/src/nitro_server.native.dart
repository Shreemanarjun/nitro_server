import 'package:nitro/nitro.dart';

part 'nitro_server.g.dart';

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.swift, windows: NativeImpl.cpp, linux: NativeImpl.cpp)
abstract class NitroServer extends HybridObject {
  static final NitroServer instance = _NitroServerImpl();

  double add(double a, double b);

  @nitroAsync
  Future<String> getGreeting(String name);
}
