import Foundation
import BackgroundTasks

/// macOS Background Transfer Daemon
/// This runs as a launchd agent and manages background file transfers
/// Communicates with Flutter UI via named pipes / Unix domain sockets

class BackgroundTransferDaemon {
    static let shared = BackgroundTransferDaemon()
    
    private let taskIdentifier = "com.connect.background-transfer-daemon"
    private var server: DispatchSourceRead?
    private var listenerSocket: Int32 = -1
    
    private init() {}
    
    func start() {
        print("Starting Connect Background Transfer Daemon...")
        
        // Set up signal handlers
        setupSignalHandlers()
        
        // Create Unix domain socket for IPC
        createIPCSocket()
        
        // Register background task
        registerBackgroundTask()
        
        // Resume incomplete transfers
        resumeIncompleteTransfers()
        
        // Keep the daemon running
        RunLoop.main.run()
    }
    
    private func setupSignalHandlers() {
        signal(SIGTERM) { _ in
            print("Received SIGTERM, shutting down...")
            BackgroundTransferDaemon.shared.shutdown()
        }
        
        signal(SIGINT) { _ in
            print("Received SIGINT, shutting down...")
            BackgroundTransferDaemon.shared.shutdown()
        }
    }
    
    private func createIPCSocket() {
        let socketPath = "/var/run/connect_transfer.sock"
        
        // Remove existing socket if present
        unlink(socketPath)
        
        let socket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else {
            print("Failed to create Unix domain socket")
            return
        }
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath.withCString { strncpy(&addr.sun_path.0, $0, sizeof(addr.sun_path) - 1) }
        
        let result = bind(socket, UnsafePointer<sockaddr>(&addr), socklen_t(MemoryLayout<sockaddr_un>.size))
        guard result == 0 else {
            print("Failed to bind socket: \(String(cString: strerror(errno)))")
            return
        }
        
        listen(socket, 5)
        listenerSocket = socket
        
        // Set up async read
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: .global())
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler {
            close(socket)
        }
        source.resume()
        
        self.server = source
        print("IPC socket listening at \(socketPath)")
    }
    
    private func acceptConnection() {
        var clientAddr = sockaddr_un()
        var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        
        let clientSocket = accept(listenerSocket, UnsafeMutablePointer<sockaddr>(&clientAddr), &addrLen)
        guard clientSocket >= 0 else {
            print("Failed to accept connection: \(String(cString: strerror(errno)))")
            return
        }
        
        // Handle client in background
        DispatchQueue.global().async { [weak self] in
            self?.handleClient(clientSocket)
        }
    }
    
    private func handleClient(_ clientSocket: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        
        while true {
            let bytesRead = read(clientSocket, &buffer, buffer.count)
            if bytesRead <= 0 {
                break
            }
            
            let data = Data(buffer.prefix(bytesRead))
            if let message = try? JSONDecoder().decode(IPCMessage.self, from: data) {
                let response = handleMessage(message)
                if let responseData = try? JSONEncoder().encode(response) {
                    write(clientSocket, responseData)
                }
            }
        }
        
        close(clientSocket)
    }
    
    private func handleMessage(_ message: IPCMessage) -> IPCResponse {
        switch message {
        case .startTransfer(let info):
            // Start transfer in background
            return .success(data: ["transfer_id": info.transferId])
        case .pauseTransfer(let transferId):
            // Pause transfer
            return .success(data: [:])
        case .resumeTransfer(let transferId):
            // Resume transfer
            return .success(data: [:])
        case .cancelTransfer(let transferId):
            // Cancel transfer
            return .success(data: [:])
        case .getStatus(let transferId):
            // Return transfer status
            return .transferStatus(id: transferId, progress: 0, speed: 0, status: "unknown")
        case .getAllTransfers:
            // Return all transfers
            return .transferList(transfers: [])
        case .registerForNotifications(let info):
            // Register for notifications
            return .success(data: [:])
        case .updateProgress(let info):
            // Update progress
            return .success(data: [:])
        case .unregisterNotifications(let transferId):
            return .success(data: [:])
        case .appInForeground(let inForeground):
            return .success(data: ["in_foreground": inForeground])
        case .resumeTransfers:
            return .transferList(transfers: [])
        case .shutdown:
            shutdown()
            return .success(data: [:])
        }
    }
    
    private func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.connect.background-transfer-checkpoint", using: nil) { task in
            self.handleBackgroundTask(task as! BGProcessingTask)
        }
        print("Registered background task")
    }
    
    private func handleBackgroundTask(_ task: BGProcessingTask) {
        // Perform checkpoint for active transfers
        task.expirationHandler = {
            print("Background task expired")
        }
        
        // In a real implementation, checkpoint active transfers
        print("Performing background checkpoint...")
        
        // Reschedule next checkpoint
        scheduleCheckpoint()
        
        task.setTaskCompleted(success: true)
    }
    
    private func scheduleCheckpoint() {
        let request = BGProcessingTaskRequest(identifier: "com.connect.background-transfer-checkpoint")
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("Scheduled background checkpoint")
        } catch {
            print("Failed to schedule checkpoint: \(error)")
        }
    }
    
    private func resumeIncompleteTransfers() {
        // Load incomplete transfers from database and resume them
        print("Resuming incomplete transfers...")
        // Implementation would load from SQLite database
    }
    
    func shutdown() {
        print("Shutting down background transfer daemon...")
        
        server?.cancel()
        if listenerSocket >= 0 {
            close(listenerSocket)
        }
        
        // Cancel background tasks
        BGTaskScheduler.shared.cancelAllTaskRequests()
        
        exit(0)
    }
}

// MARK: - IPC Types

struct IPCMessage: Codable {
    let type: String
    let payload: Data
    
    enum MessageType: String, Codable {
        case startTransfer = "start_transfer"
        case pauseTransfer = "pause_transfer"
        case resumeTransfer = "resume_transfer"
        case cancelTransfer = "cancel_transfer"
        case getStatus = "get_status"
        case getAllTransfers = "get_all_transfers"
        case registerNotifications = "register_notifications"
        case updateProgress = "update_progress"
        case unregisterNotifications = "unregister_notifications"
        case appInForeground = "app_in_foreground"
        case resumeTransfers = "resume_transfers"
        case shutdown = "shutdown"
    }
}

struct IPCResponse: Codable {
    let type: String
    let data: Data?
    let error: String?
    
    static func success(data: [String: Any]) -> IPCResponse {
        return IPCResponse(type: "success", data: try? JSONSerialization.data(withJSONObject: data), error: nil)
    }
    
    static func transferStatus(id: String, progress: Float, speed: UInt64, status: String) -> IPCResponse {
        let data = try? JSONSerialization.data(withJSONObject: [
            "transfer_id": id,
            "progress": progress,
            "speed_bps": speed,
            "status": status
        ])
        return IPCResponse(type: "transfer_status", data: data, error: nil)
    }
    
    static func transferList(transfers: [[String: Any]]) -> IPCResponse {
        let data = try? JSONSerialization.data(withJSONObject: ["transfers": transfers])
        return IPCResponse(type: "transfer_list", data: data, error: nil)
    }
    
    static func error(_ message: String) -> IPCResponse {
        return IPCResponse(type: "error", data: nil, error: message)
    }
}