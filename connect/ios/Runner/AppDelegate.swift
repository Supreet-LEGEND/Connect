import Flutter
import UIKit
import BackgroundTasks

@main
@objc class AppDelegate: FlutterAppDelegate {
    private let backgroundTaskIdentifier = "com.connect.background-transfer-checkpoint"
    
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        let controller = window?.rootViewController as! FlutterViewController

        // WiFi Settings Channel
        let wifiChannel = FlutterMethodChannel(
            name: "wifi_settings",
            binaryMessenger: controller.binaryMessenger
        )

        // Transfer Control Channel
        let transferChannel = FlutterMethodChannel(
            name: "connect/transfer_control",
            binaryMessenger: controller.binaryMessenger
        )
        transferChannel.setMethodCallHandler { [weak self] call, result in
            switch call.method {
            case "getActiveTransfers":
                // Return active transfers from Dart state
                result.success([:])
            case "scheduleBackgroundCheckpoint":
                if let transferIds = call.arguments as? [String] {
                    self?.scheduleBackgroundCheckpoint(transferIds: transferIds)
                    result.success(true)
                } else {
                    result.success(false)
                }
            case "cancelBackgroundTasks":
                self?.cancelBackgroundTasks()
                result.success(true)
            default:
                result.notImplemented()
            }
        }

        // Register background task
        registerBackgroundTask()

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    
    override func applicationDidEnterBackground(_ application: UIApplication) {
        // Get active transfer IDs from Dart and schedule checkpoint
        // For now, we'll use a notification to get transfer IDs from Dart
        NotificationCenter.default.post(name: NSNotification.Name("AppDidEnterBackground"), object: nil)
    }
    
    override func applicationDidBecomeActive(_ application: UIApplication) {
        // Cancel background tasks when app becomes active
        cancelBackgroundTasks()
    }
    
    // Handle background URL session completion
    override func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        // Store completion handler for later
        completionHandler()
    }
    
    // MARK: - Background Task Registration
    
    private func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskIdentifier, using: nil) { task in
            self.handleBackgroundCheckpoint(task as! BGProcessingTask)
        }
    }
    
    private func scheduleBackgroundCheckpoint(transferIds: [String]) {
        let request = BGProcessingTaskRequest(identifier: backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 10) // 10 seconds from now
        
        // Pass transfer IDs to resume
        request.setValue(transferIds.joined(separator: ","), forKey: "transferIds")
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("Scheduled background checkpoint for transfers: \(transferIds)")
        } catch {
            print("Failed to schedule background checkpoint: \(error)")
        }
    }
    
    private func handleBackgroundCheckpoint(_ task: BGProcessingTask) {
        // Get transfer IDs from task
        guard let transferIdsString = task.userInfo?["transferIds"] as? String else {
            task.setTaskCompleted(success: false)
            return
        }
        
        let transferIds = transferIdsString.split(separator: ",").map(String.init)
        
        // Set expiration handler
        task.expirationHandler = {
            // Save progress and cancel
            self.saveProgressForTransfers(transferIds)
            task.setTaskCompleted(success: false)
        }
        
        // Perform checkpoint for each transfer
        for transferId in transferIds {
            checkpointTransfer(transferId)
        }
        
        // Reschedule next checkpoint
        scheduleBackgroundCheckpoint(transferIds: transferIds)
        
        task.setTaskCompleted(success: true)
    }
    
    private func checkpointTransfer(_ transferId: String) {
        // In a real implementation, this would:
        // 1. Get the transfer state from the database
        // 2. Save current chunk position
        // 3. Update the progress in the UI when app resumes
        print("Checkpointing transfer: \(transferId)")
    }
    
    private func saveProgressForTransfers(_ transferIds: [String]) {
        for transferId in transferIds {
            checkpointTransfer(transferId)
        }
    }
    
    private func cancelBackgroundTasks() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundTaskIdentifier)
    }
}