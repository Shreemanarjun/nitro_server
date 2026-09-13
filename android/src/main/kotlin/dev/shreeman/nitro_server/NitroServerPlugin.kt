package dev.shreeman.nitro_server

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import nitro.nitro_server_module.NitroServerJniBridge

class NitroServerPlugin : FlutterPlugin, ActivityAware {

    companion object {
        init { System.loadLibrary("nitro_server") }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // registerFactory: one impl per Dart-side instance (multi-instance
        // registry). The old single-instance register(impl, context) API no
        // longer exists on the generated JniBridge.
        NitroServerJniBridge.registerFactory({ NitroServerImpl() }, binding.applicationContext)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        NitroServerJniBridge.onDetached()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        NitroServerJniBridge.onActivityAttached(binding.activity)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        NitroServerJniBridge.onActivityDetached()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        NitroServerJniBridge.onActivityAttached(binding.activity)
    }

    override fun onDetachedFromActivity() {
        NitroServerJniBridge.onActivityDetached()
    }
}