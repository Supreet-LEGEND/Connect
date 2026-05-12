package com.example.connect

import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Context
import java.lang.reflect.Method


class MainActivity: FlutterActivity() {
    private val CHANNEL = "hotspot_status"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isHotspotEnabled" -> {
                        val enabled = isHotspotOn()
                        result.success(enabled)
                    }
                    "openHotspotSettings" -> {
                        val launched = openHotspotSettings()
                        result.success(launched)
                    }
                    else -> result.notImplemented()
                }
            }

         MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "wifi_settings")
    .setMethodCallHandler { call, result ->
        if (call.method == "openWifiSettings") {
            val intent = Intent(Settings.ACTION_WIFI_SETTINGS)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            result.success(null)
        }
        
        else if (call.method == "isWifiEnabled") {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val enabled = wifiManager.isWifiEnabled
            result.success(enabled)
                }
        else {
            result.notImplemented()
        }
    }



    }

    // Uses reflection to call WifiManager.isWifiApEnabled() (works on many Android versions)
    private fun isHotspotOn(): Boolean {
        return try {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val method: Method = wifiManager.javaClass.getDeclaredMethod("isWifiApEnabled")
            method.isAccessible = true
            method.invoke(wifiManager) as Boolean
        } catch (e: Exception) {
            // If reflection fails or API not available, return false
            false
        }
    }

    // Launch the tethering / hotspot settings screen. Returns true if intent launched.
    private fun openHotspotSettings(): Boolean {
        return try {
            // Preferred: take the user to Wi-Fi Tethering settings directly
            // val intent = Intent(Settings.ACTION_WIRELESS_SETTINGS)
            val intent = Intent("android.settings.TETHER_SETTINGS")
            // Alternatively: Intent(Settings.ACTION_TETHER_SETTINGS)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

   


}

