import Foundation
import BackgroundTasks

/// Background task handler for iOS/macOS
/// Handles periodic checkpointing of large transfers when app is backgrounded

class BackgroundTransferTask {
    static let shared = BackgroundTransferTask()
    
    private let taskIdentifier = "com.connect.background-transfer-checkpoint"
    private let checkpointInterval: TimeInterval = 10.0 // seconds
    
    private init() {}
    
    /// Register background task with the system
    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            self.handleCheckpointTask(task as! BGProcessingTask)
        }
    }
    
    /// Schedule a background checkpoint task
    func scheduleCheckpoint(transferIds: [String]) {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: checkpointInterval)
        
        // Pass transfer IDs to resume
        request.setValue(transferIds.joined(separator: ","), forKey: "transferIds")
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("Scheduled background checkpoint for transfers: \(transferIds)")
        } catch {
            print("Failed to schedule background checkpoint: \(error)")
        }
    }
    
    /// Handle the background checkpoint task
    private func handleCheckpointTask(_ task: BGProcessingTask) {
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
        scheduleCheckpoint(transferIds: transferIds)
        
        task.setTaskCompleted(success: true)
    }
    
    /// Save progress for a specific transfer
    private func checkpointTransfer(_ transferId: String) {
        // In a real implementation, this would:
        // 1. Get the transfer state from the database
        // 2. Save current chunk position
        // 3. Update the progress in the UI when app resumes
        
        print("Checkpointing transfer: \(transferId)")
    }
    
    /// Save progress for multiple transfers
    private func saveProgressForTransfers(_ transferIds: [String]) {
        for transferId in transferIds {
            checkpointTransfer(transferId)
        }
    }
    
    /// Called when app enters background with active transfers
    func appDidEnterBackground(withActiveTransfers transferIds: [String]) {
        // Schedule immediate checkpoint
        scheduleCheckpoint(transferIds: transferIds)
    }
    
    /// Called when app becomes active
    func appDidBecomeActive() {
        // Cancel any pending background tasks
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }
}

/// AppDelegate extension for background task handling
extension AppDelegate {
    func application(_ application: UIApplication, 
                     handleEventsForBackgroundURLSession identifier: String, 
                     completionHandler: @escaping () -> Void) {
        // Handle background URL session completion
        completionHandler()
    }
}