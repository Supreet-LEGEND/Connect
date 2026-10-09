package com.connect.app;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.FlutterEngineCache;
import io.flutter.embedding.engine.dart.DartExecutor;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

import java.util.HashMap;
import java.util.Map;

public class BackgroundTransferService extends Service {
    private static final String TAG = "BackgroundTransferService";
    private static final String CHANNEL_ID = "connect_transfer_channel";
    private static final int NOTIFICATION_ID = 1001;
    private static final String METHOD_CHANNEL = "connect/transfer_notifications";

    private FlutterEngine flutterEngine;
    private NotificationManager notificationManager;
    private MethodChannel methodChannel;
    private boolean appInForeground = false;

    // Track all active transfers
    private final Map<String, TransferInfo> activeTransfers = new HashMap<>();

    static class TransferInfo {
        final String transferId;
        final String fileName;
        final long totalSize;
        int progress = 0;
        long speed = 0;
        boolean isBackground = false;

        TransferInfo(String transferId, String fileName, long totalSize) {
            this.transferId = transferId;
            this.fileName = fileName;
            this.totalSize = totalSize;
        }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();
        notificationManager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        setupMethodChannel();
    }

    private void setupMethodChannel() {
        // Initialize Flutter engine for MethodChannel
        if (flutterEngine == null) {
            flutterEngine = new FlutterEngine(this);
            flutterEngine.getDartExecutor().executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault()
            );
            FlutterEngineCache.getInstance().put("background_transfer", flutterEngine);
        }

        methodChannel = new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), METHOD_CHANNEL);
        methodChannel.setMethodCallHandler(new MethodCallHandler() {
            @Override
            public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
                switch (call.method) {
                    case "registerTransfer":
                        String transferId = call.argument("transferId");
                        String fileName = call.argument("fileName");
                        Long totalSize = call.argument("totalSize");
                        registerTransfer(transferId, fileName, totalSize != null ? totalSize : 0L);
                        result.success(true);
                        break;
                    case "updateTransferProgress":
                        String progressTransferId = call.argument("transferId");
                        Integer progress = call.argument("progress");
                        Long speed = call.argument("speed");
                        updateTransferProgress(progressTransferId, progress != null ? progress : 0, speed != null ? speed : 0L);
                        result.success(true);
                        break;
                    case "unregisterTransfer":
                        String unregisterTransferId = call.argument("transferId");
                        unregisterTransfer(unregisterTransferId);
                        result.success(true);
                        break;
                    case "setAppInForeground":
                        Boolean inForeground = call.argument("inForeground");
                        setAppInForeground(inForeground != null && inForeground);
                        result.success(true);
                        break;
                    case "getActiveTransfers":
                        // Return list of active transfers
                        Map<String, Object> transfers = new HashMap<>();
                        for (Map.Entry<String, TransferInfo> entry : activeTransfers.entrySet()) {
                            Map<String, Object> info = new HashMap<>();
                            info.put("transferId", entry.getValue().transferId);
                            info.put("fileName", entry.getValue().fileName);
                            info.put("totalSize", entry.getValue().totalSize);
                            info.put("progress", entry.getValue().progress);
                            info.put("speed", entry.getValue().speed);
                            info.put("isBackground", entry.getValue().isBackground);
                            transfers.put(entry.getKey(), info);
                        }
                        result.success(transfers);
                        break;
                    default:
                        result.notImplemented();
                }
            }
        });
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null) {
            String action = intent.getAction();
            if ("START_TRANSFER".equals(action)) {
                startTransfer(intent);
            } else if ("STOP_TRANSFER".equals(action)) {
                stopTransfer(intent);
            } else if ("UPDATE_PROGRESS".equals(action)) {
                updateProgress(intent);
            } else if ("PAUSE_TRANSFER".equals(action)) {
                pauseTransfer(intent);
            } else if ("CANCEL_TRANSFER".equals(action)) {
                cancelTransfer(intent);
            }
        }
        return START_STICKY;
    }

    private void startTransfer(Intent intent) {
        // Register transfer for notification tracking
        String transferId = intent.getStringExtra("transferId");
        String fileName = intent.getStringExtra("fileName");
        long fileSize = intent.getLongExtra("fileSize", 0);
        
        if (transferId != null) {
            registerTransfer(transferId, fileName != null ? fileName : "Unknown", fileSize);
            TransferInfo info = activeTransfers.get(transferId);
            if (info != null) {
                info.isBackground = true;
            }
        }

        // Start foreground notification
        Notification notification = createNotification("Starting transfer...", 0);
        startForeground(NOTIFICATION_ID, notification);

        // Initialize Flutter engine for background isolate (if not already)
        if (flutterEngine == null) {
            flutterEngine = new FlutterEngine(this);
            flutterEngine.getDartExecutor().executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault()
            );
            FlutterEngineCache.getInstance().put("background_transfer", flutterEngine);
            // Re-setup MethodChannel since we have a new engine
            setupMethodChannel();
        }

        // Pass transfer parameters to Dart entrypoint
        String deviceId = intent.getStringExtra("deviceId");
        String filePath = intent.getStringExtra("filePath");
        long size = intent.getLongExtra("fileSize", 0);

        // Here we would communicate with the Dart background isolate
        // For now, just show the notification
        updateNotification("Transfer queued: " + transferId, 0);
    }

    private void stopTransfer(Intent intent) {
        String transferId = intent.getStringExtra("transferId");
        if (transferId != null) {
            unregisterTransfer(transferId);
        }
        // Stop the transfer in Dart isolate
        updateNotification("Transfer stopped: " + transferId, 0);
    }

    private void pauseTransfer(Intent intent) {
        String transferId = intent.getStringExtra("transferId");
        // Pause the transfer in Dart isolate
        if (methodChannel != null) {
            methodChannel.invokeMethod("pauseTransfer", Map.of("transferId", transferId));
        }
        updateNotification("Transfer paused: " + transferId, -1);
    }

    private void cancelTransfer(Intent intent) {
        String transferId = intent.getStringExtra("transferId");
        if (transferId != null) {
            unregisterTransfer(transferId);
        }
        // Cancel the transfer in Dart isolate
        if (methodChannel != null) {
            methodChannel.invokeMethod("cancelTransfer", Map.of("transferId", transferId));
        }
        updateNotification("Transfer cancelled: " + transferId, 0);
    }

    private void updateProgress(Intent intent) {
        String transferId = intent.getStringExtra("transferId");
        int progress = intent.getIntExtra("progress", 0);
        long speed = intent.getLongExtra("speed", 0);
        
        String speedStr = formatSpeed(speed);
        updateTransferProgress(transferId, progress, speed);
        updateNotification("Transfer: " + transferId + " - " + progress + "% - " + speedStr, progress);
    }

    private void registerTransfer(String transferId, String fileName, long totalSize) {
        if (transferId == null) return;
        TransferInfo info = new TransferInfo(transferId, fileName, totalSize);
        activeTransfers.put(transferId, info);
        updateNotificationVisibility();
    }

    private void unregisterTransfer(String transferId) {
        if (transferId == null) return;
        activeTransfers.remove(transferId);
        updateNotificationVisibility();
    }

    private void updateTransferProgress(String transferId, int progress, long speed) {
        if (transferId == null) return;
        TransferInfo info = activeTransfers.get(transferId);
        if (info != null) {
            info.progress = progress;
            info.speed = speed;
            updateNotificationVisibility();
        }
    }

    private void setAppInForeground(boolean inForeground) {
        this.appInForeground = inForeground;
        updateNotificationVisibility();
    }

    private void updateNotificationVisibility() {
        if (activeTransfers.isEmpty()) {
            // No active transfers - stop foreground service and hide notification
            stopForeground(true);
            notificationManager.cancel(NOTIFICATION_ID);
        } else {
            // Has active transfers - show notification
            boolean anyBackground = false;
            for (TransferInfo info : activeTransfers.values()) {
                if (info.isBackground) {
                    anyBackground = true;
                    break;
                }
            }
            
            if (anyBackground || !appInForeground) {
                // Background transfer or app in background - use startForeground
                Notification notification = createAggregatedNotification();
                startForeground(NOTIFICATION_ID, notification);
            } else {
                // App in foreground - show notification but don't use startForeground
                Notification notification = createAggregatedNotification();
                notificationManager.notify(NOTIFICATION_ID, notification);
            }
        }
    }

    private Notification createAggregatedNotification() {
        Intent contentIntent = new Intent(this, MainActivity.class);
        contentIntent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
        PendingIntent pendingIntent = PendingIntent.getActivity(
            this, 0, contentIntent, PendingIntent.FLAG_IMMUTABLE);

        // Build aggregated notification for all transfers
        StringBuilder contentText = new StringBuilder();
        int totalProgress = 0;
        int count = 0;
        
        for (TransferInfo info : activeTransfers.values()) {
            contentText.append(info.fileName).append(": ").append(info.progress).append("%\n");
            totalProgress += info.progress;
            count++;
        }
        
        int avgProgress = count > 0 ? totalProgress / count : 0;

        NotificationCompat.Builder builder = new NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Connect - " + count + " Transfer(s) Active")
            .setContentText(contentText.toString().trim())
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(pendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setOnlyAlertOnce(true)
            .setOngoing(true);

        if (avgProgress >= 0) {
            builder.setProgress(100, avgProgress, avgProgress == 0);
        }

        // Add actions for each transfer (limit to 3)
        int actionCount = 0;
        for (TransferInfo info : activeTransfers.values()) {
            if (actionCount >= 3) break;
            
            Intent pauseIntent = new Intent(this, BackgroundTransferService.class);
            pauseIntent.setAction("PAUSE_TRANSFER");
            pauseIntent.putExtra("transferId", info.transferId);
            PendingIntent pausePendingIntent = PendingIntent.getService(
                this, actionCount, pauseIntent, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
            builder.addAction(R.drawable.ic_pause, "Pause " + info.fileName, pausePendingIntent);
            actionCount++;
        }
        
        // Add cancel all action
        Intent cancelIntent = new Intent(this, BackgroundTransferService.class);
        cancelIntent.setAction("CANCEL_ALL");
        PendingIntent cancelPendingIntent = PendingIntent.getService(
            this, 100, cancelIntent, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        builder.addAction(R.drawable.ic_cancel, "Cancel All", cancelPendingIntent);

        return builder.build();
    }

    private Notification createNotification(String text, int progress) {
        Intent contentIntent = new Intent(this, MainActivity.class);
        contentIntent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
        PendingIntent pendingIntent = PendingIntent.getActivity(
            this, 0, contentIntent, PendingIntent.FLAG_IMMUTABLE);

        NotificationCompat.Builder builder = new NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Connect - File Transfer")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(pendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setOnlyAlertOnce(true)
            .setOngoing(true);

        if (progress >= 0) {
            builder.setProgress(100, progress, progress == 0);
        }

        // Add actions for pause/cancel
        Intent pauseIntent = new Intent(this, BackgroundTransferService.class);
        pauseIntent.setAction("PAUSE_TRANSFER");
        pauseIntent.putExtra("transferId", "current");
        PendingIntent pausePendingIntent = PendingIntent.getService(
            this, 1, pauseIntent, PendingIntent.FLAG_IMMUTABLE);
        builder.addAction(R.drawable.ic_pause, "Pause", pausePendingIntent);

        Intent cancelIntent = new Intent(this, BackgroundTransferService.class);
        cancelIntent.setAction("CANCEL_TRANSFER");
        cancelIntent.putExtra("transferId", "current");
        PendingIntent cancelPendingIntent = PendingIntent.getService(
            this, 2, cancelIntent, PendingIntent.FLAG_IMMUTABLE);
        builder.addAction(R.drawable.ic_cancel, "Cancel", cancelPendingIntent);

        return builder.build();
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID,
                "File Transfers",
                NotificationManager.IMPORTANCE_LOW
            );
            channel.setDescription("Background file transfer progress");
            channel.enableVibration(false);
            channel.setSound(null, null);
            notificationManager = getSystemService(NotificationManager.class);
            notificationManager.createNotificationChannel(channel);
        }
    }

    private String formatSpeed(long bytesPerSecond) {
        if (bytesPerSecond < 1024) {
            return bytesPerSecond + " B/s";
        } else if (bytesPerSecond < 1024 * 1024) {
            return String.format("%.1f KB/s", bytesPerSecond / 1024.0);
        } else {
            return String.format("%.1f MB/s", bytesPerSecond / (1024.0 * 1024.0));
        }
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onDestroy() {
        super.onDestroy();
        if (flutterEngine != null) {
            flutterEngine.destroy();
            flutterEngine = null;
        }
        if (methodChannel != null) {
            methodChannel.setMethodCallHandler(null);
            methodChannel = null;
        }
    }
}
