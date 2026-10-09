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
    private val TRANSFER_CHANNEL = "connect/transfer_control"
    private val NOTIFICATION_CHANNEL = "connect/transfer_notifications"

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

        // Transfer Control Channel - for starting/stopping background transfers
        MethodChannel(flutterEngine.dartExecutor.binaryMessesser, TRANSFER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startBackgroundTransfer" -> {
                        val transferId = call.argument<String>("transferId")!!
                        val deviceId = call.argument<String>("deviceId")!!
                        val filePath = call.argument<String>("filePath")!!
                        val fileSize = call.argument<Long>("fileSize")!!
                        
                        startBackgroundTransfer(transferId, deviceId, filePath, fileSize)
                        result.success(true)
                    }
                    "stopBackgroundTransfer" -> {
                        val transferId = call.argument<String>("transferId")!!
                        stopBackgroundTransfer(transferId)
                        result.success(true)
                    }
                    "pauseBackgroundTransfer" -> {
                        val transferId = call.argument<String>("transferId")!!
                        pauseBackgroundTransfer(transferId)
                        result.success(true)
                    }
                    "cancelBackgroundTransfer" -> {
                        val transferId = call.argument<String>("transferId")!!
                        cancelBackgroundTransfer(transferId)
                        result.success(true)
                    }
                    "getActiveTransfers" -> {
                        // Get active transfers from background service
                        getActiveTransfersFromService(result)
                    }
                    "setAppInForeground" -> {
                        val inForeground = call.argument<Boolean>("inForeground")!!
                        setAppInForeground(inForeground)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // Transfer Notifications Channel - for progress updates from background service
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NOTIFICATION_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "registerTransfer" -> {
                        val transferId = call.argument<String>("transferId")!!
                        val fileName = call.argument<String>("fileName")!!
                        val totalSize = call.argument<Long>("totalSize")!!
                        registerTransferNotification(transferId, fileName, totalSize)
                        result.success(true)
                    }
                    "updateTransferProgress" -> {
                        val transferId = call.argument<String>("transferId")!!
                        val progress = call.argument<Int>("progress")!!
                        val speed = call.argument<Long>("speed")!!
                        updateTransferNotificationProgress(transferId, progress, speed)
                        result.success(true)
                    }
                    "unregisterTransfer" -> {
                        val transferId = call.argument<String>("transferId")!!
                        unregisterTransferNotification(transferId)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // Transfer control methods
    private fun startBackgroundTransfer(transferId: String, deviceId: String, filePath: String, fileSize: Long) {
        Intent serviceIntent = Intent(this, BackgroundTransferService::class.java)
        serviceIntent.action = "START_TRANSFER"
        serviceIntent.putExtra("transferId", transferId)
        serviceIntent.putExtra("deviceId", deviceId)
        serviceIntent.putExtra("filePath", filePath)
        serviceIntent.putExtra("fileSize", fileSize)

        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }
    }

    private fun stopBackgroundTransfer(transferId: String) {
        Intent serviceIntent = Intent(this, BackgroundTransferService::class.java)
        serviceIntent.action = "STOP_TRANSFER"
        serviceIntent.putExtra("transferId", transferId)
        startService(serviceIntent)
    }

    private fun pauseBackgroundTransfer(transferId: String) {
        Intent serviceIntent = Intent(this, BackgroundTransferService::class.java)
        serviceIntent.action = "PAUSE_TRANSFER"
        serviceIntent.putExtra("transferId", transferId)
        startService(serviceIntent)
    }

    private fun cancelBackgroundTransfer(transferId: String) {
        Intent serviceIntent = Intent(this, BackgroundTransferService::class.java)
        serviceIntent.action = "CANCEL_TRANSFER"
        serviceIntent.putExtra("transferId", transferId)
        startService(serviceIntent)
    }

    private fun getActiveTransfersFromService(result: MethodChannel.Result) {
        // Forward to background service via MethodChannel
        // For now return empty list - background service will push updates
        result.success(emptyMap<String, Any>())
    }

    private fun setAppInForeground(inForeground: Boolean) {
        // Notify background service of app state
        Intent serviceIntent = Intent(this, BackgroundTransferService::class.java)
        serviceIntent.putExtra("inForeground", inForeground)
        startService(serviceIntent)
    }

    // Notification methods (forward to BackgroundTransferService)
    private fun registerTransferNotification(transferId: String, fileName: String, totalSize: Long) {
        Intent serviceIntent = Intent(this, BackgroundTransferService::class.java)
        serviceIntent.putExtra("transferId", transferId)
        serviceIntent.putExtra("fileName", fileName)
        serviceIntent.putExtra("totalSize", totalSize)
        serviceIntent.putExtra("registerForNotification", true)
        startService(serviceIntent)
    }

    private fun updateTransferNotificationProgress(transferId: String, progress: Int, speed: Long) {
        Intent serviceIntent = Intent(this, BackgroundTransferService::class.java)
        serviceIntent.action = "UPDATE_PROGRESS"
        serviceIntent.putExtra("transferId", transferId)
        serviceIntent.putExtra("progress", progress)
        serviceIntent.putExtra("speed", speed)
        startService(serviceIntent)
    }

    private fun unregisterTransferNotification(transferId: String) {
        Intent serviceIntent = Intent(this, BackgroundTransferService::class.java)
        serviceIntent.putExtra("transferId", transferId)
        serviceIntent.putExtra("unregisterForNotification", true)
        startService(serviceIntent)
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