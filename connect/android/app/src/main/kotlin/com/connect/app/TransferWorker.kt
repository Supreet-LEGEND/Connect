package com.connect.app;

import android.content.Context;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.work.Worker;
import androidx.work.WorkerParameters;

import com.connect.app.BackgroundTransferService;

public class TransferWorker extends Worker {
    private static final String TAG = "TransferWorker";

    public TransferWorker(@NonNull Context context, @NonNull WorkerParameters workerParams) {
        super(context, workerParams);
    }

    @NonNull
    @Override
    public Result doWork() {
        // Get transfer parameters from input data
        String transferId = getInputData().getString("transferId");
        String deviceId = getInputData().getString("deviceId");
        String filePath = getInputData().getString("filePath");
        long fileSize = getInputData().getLong("fileSize", 0);

        Log.d(TAG, "Starting background transfer: " + transferId);

        // Start the foreground service
        Intent serviceIntent = new Intent(getApplicationContext(), BackgroundTransferService.class);
        serviceIntent.setAction("START_TRANSFER");
        serviceIntent.putExtra("transferId", transferId);
        serviceIntent.putExtra("deviceId", deviceId);
        serviceIntent.putExtra("filePath", filePath);
        serviceIntent.putExtra("fileSize", fileSize);

        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            getApplicationContext().startForegroundService(serviceIntent);
        } else {
            getApplicationContext().startService(serviceIntent);
        }

        return Result.success();
    }
}