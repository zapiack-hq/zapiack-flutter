package com.zapiack.flutter

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import com.zapiack.push.ZapiackPush
import com.zapiack.push.core.Tap
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry

/** Connects the Dart API to the Android library. */
class ZapiackPushPlugin :
    FlutterPlugin,
    MethodCallHandler,
    ActivityAware,
    PluginRegistry.NewIntentListener,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var binding: ActivityPluginBinding? = null
    private var pendingPermission: Result? = null

    /** The tap that opened the app, kept until Dart asks for it, because Dart is not listening yet when the app starts. */
    private var initialTap: Tap? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "com.zapiack.push")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "configure" -> {
                val key = call.argument<String>("appKey")
                if (key == null || !key.startsWith("pk_")) return result.error("invalid_key", "The app key must start with pk_", null)
                val base = call.argument<String>("baseUrl")
                if (base != null) ZapiackPush.configure(context, key, base) else ZapiackPush.configure(context, key)
                result.success(null)
            }
            "requestPermission" -> requestPermission(result)
            "installationId" -> result.success(ZapiackPush.installationId)
            "login" -> { ZapiackPush.login(call.argument<String>("userId") ?: return result.error("invalid_argument", "userId is required", null)); result.success(null) }
            "logout" -> { ZapiackPush.logout(); result.success(null) }
            "addTags" -> { ZapiackPush.addTags(call.argument<Map<String, Any?>>("tags") ?: emptyMap()); result.success(null) }
            "removeTags" -> { ZapiackPush.removeTags(call.argument<List<String>>("keys") ?: emptyList()); result.success(null) }
            "screen" -> { ZapiackPush.screen(call.argument<String>("name") ?: return result.error("invalid_argument", "name is required", null)); result.success(null) }
            "track" -> {
                val name = call.argument<String>("name") ?: return result.error("invalid_argument", "name is required", null)
                result.success(ZapiackPush.track(name, call.argument<Map<String, Any?>>("properties")))
            }
            "flush" -> { ZapiackPush.flush(); result.success(null) }
            "initialTap" -> { result.success(initialTap?.toMap()); initialTap = null }
            else -> result.notImplemented()
        }
    }

    private fun requestPermission(result: Result) {
        val activity = binding?.activity
        if (activity == null) return result.error("no_activity", "There is no screen to ask on", null)
        if (ZapiackPush.hasPermission(activity)) {
            ZapiackPush.requestPermission(activity) // already allowed: this only registers
            return result.success(true)
        }
        pendingPermission?.success(false)
        pendingPermission = result
        ZapiackPush.requestPermission(activity)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        val pending = pendingPermission ?: return false
        ZapiackPush.onPermissionResult(requestCode)
        pendingPermission = null
        pending.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
        return true
    }

    private fun handle(activity: Activity, intent: Intent?, cold: Boolean) {
        val tap = ZapiackPush.handleIntent(intent) ?: return
        if (cold) initialTap = tap else channel.invokeMethod("tap", tap.toMap())
    }

    override fun onNewIntent(intent: Intent): Boolean {
        binding?.activity?.let { handle(it, intent, cold = false) }
        return false
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addOnNewIntentListener(this)
        binding.addRequestPermissionsResultListener(this)
        handle(binding.activity, binding.activity.intent, cold = true)
    }

    override fun onDetachedFromActivity() {
        binding?.removeOnNewIntentListener(this)
        binding?.removeRequestPermissionsResultListener(this)
        binding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
}

private fun Tap.toMap(): Map<String, Any?> = mapOf(
    "messageId" to messageId,
    "deliveryId" to deliveryId,
    "sessionId" to sessionId,
    "actionId" to actionId,
    "event" to event,
    "link" to link,
)
