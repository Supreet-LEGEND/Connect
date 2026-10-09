package com.connect.app;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

public class BootReceiver extends BroadcastReceiver {
    private static final String TAG = "BootReceiver";

    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent.getAction();
        if (Intent.ACTION_BOOT_COMPLETED.equals(action) || 
            Intent.ACTION_QUICKBOOT_POWERON.equals(action)) {
            Log.d(TAG, "Device booted, scheduling transfer resume check");
            
            // Start the transfer service to check for incomplete transfers
            Intent serviceIntent = new Intent(context, BackgroundTransferService.class);
            serviceIntent.setAction("RESUME_TRANSFERS");
            
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent);
            } else {
                context.startService(serviceIntent);
            }
        }
    }
}