package com.example.wifi_connection

import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.provider.Settings
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class WifiConnectionPlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context   // <-- IMPORTANT

    override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "wifi_connection")
        channel.setMethodCallHandler(this)
        appContext = binding.applicationContext   // <-- CORRECT CONTEXT
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        when (call.method) {

            // ------------------------------------------------------------------
            // CHECK IF WIFI IS ENABLED
            // ------------------------------------------------------------------
            "isWifiEnabled" -> {
                val wifiManager =
                    appContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                result.success(wifiManager.isWifiEnabled)
            }

            // ------------------------------------------------------------------
            // OPEN WIFI SETTINGS
            // ------------------------------------------------------------------
            "openWifiSettings" -> {
                val intent = Intent(Settings.ACTION_WIFI_SETTINGS).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                appContext.startActivity(intent)
                result.success(true)
            }

            // ------------------------------------------------------------------
            // CHECK HOTSPOT STATE (reflection API)
            // ------------------------------------------------------------------
            "isHotspotEnabled" -> {
                result.success(isHotspotOn())
            }

            // ------------------------------------------------------------------
            // OPEN HOTSPOT SETTINGS
            // ------------------------------------------------------------------
            "openHotspotSettings" -> {
                val intent = Intent(Settings.ACTION_WIRELESS_SETTINGS).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                appContext.startActivity(intent)
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    // ------------------------------------------------------------------
    // CHECK MOBILE HOTSPOT ON (NOT OFFICIAL API)
    // ------------------------------------------------------------------
    private fun isHotspotOn(): Boolean {
        return try {
            val wifiManager =
                appContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

            val method = wifiManager.javaClass.getDeclaredMethod("isWifiApEnabled")
            method.isAccessible = true
            method.invoke(wifiManager) as Boolean
        } catch (e: Exception) {
            false
        }
    }
}
