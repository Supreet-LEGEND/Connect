use std::sync::Arc;
use std::time::Duration;
use windows_service::service::{
    ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus, ServiceType,
};
use windows_service::service_control_handler::{self, ServiceControlHandlerResult};
use windows_service::service_dispatcher;
use windows::Win32::Foundation::*;
use windows::Win32::System::Threading::*;
use windows::Win32::Networking::WinSock::*;
use windows::Win32::Storage::FileSystem::*;
use anyhow::Result;
use tokio::sync::mpsc;
use serde::{Deserialize, Serialize};

mod ipc;
mod transfer;

use ipc::NamedPipeServer;
use transfer::TransferManager;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ServiceConfig {
    dart_entrypoint: String,
    dart_args: Vec<String>,
    named_pipe_name: String,
    log_level: String,
}

impl Default for ServiceConfig {
    fn default() -> Self {
        Self {
            dart_entrypoint: "background_transfer_entrypoint".to_string(),
            dart_args: vec![],
            named_pipe_name: r"\\.\pipe\connect_transfer".to_string(),
            log_level: "info".to_string(),
        }
    }
}

struct ConnectTransferService {
    config: ServiceConfig,
    transfer_manager: Arc<TransferManager>,
    shutdown_tx: Option<mpsc::Sender<()>>,
    pipe_server: Option<NamedPipeServer>,
}

impl ConnectTransferService {
    fn new(config: ServiceConfig) -> Self {
        let transfer_manager = Arc::new(TransferManager::new());
        Self {
            config,
            transfer_manager,
            shutdown_tx: None,
            pipe_server: None,
        }
    }

    fn start(&mut self) -> Result<()> {
        // Initialize Dart runtime (would load AOT snapshot)
        self.initialize_dart_runtime()?;

        // Set up notification handler for Windows toast notifications
        let transfer_manager = self.transfer_manager.clone();
        self.transfer_manager.set_notification_handler(Arc::new(move |info| {
            Self::show_toast_notification(info);
        }));

        // Start named pipe server for IPC with UI
        let (shutdown_tx, mut shutdown_rx) = mpsc::channel(1);
        self.shutdown_tx = Some(shutdown_tx);

        let pipe_name = self.config.named_pipe_name.clone();
        let transfer_manager = self.transfer_manager.clone();
        
        self.pipe_server = Some(NamedPipeServer::new(pipe_name, move |msg| {
            transfer_manager.handle_ipc_message(msg)
        }));

        // Start the pipe server in background
        tokio::spawn(async move {
            if let Some(server) = &self.pipe_server {
                server.run().await;
            }
        });

        // Resume incomplete transfers on startup
        self.resume_incomplete_transfers();

        Ok(())
    }

    fn initialize_dart_runtime(&self) -> Result<()> {
        // In a real implementation, this would:
        // 1. Load the Dart AOT snapshot
        // 2. Initialize the Dart VM
        // 3. Call the background_transfer_entrypoint function
        // For now, we'll just log
        tracing::info!("Initializing Dart runtime for background transfers");
        Ok(())
    }

    fn resume_incomplete_transfers(&self) {
        // On service startup, check for incomplete transfers and resume them
        let response = self.transfer_manager.handle_ipc_message(
            ipc::IpcMessage::ResumeTransfers
        );
        
        if let ipc::IpcResponse::TransferList { transfers } = response {
            for transfer in transfers {
                if transfer.status == "in_progress" || transfer.status == "paused" || transfer.status == "queued" {
                    tracing::info!("Auto-resuming transfer: {}", transfer.id);
                    // In real implementation, resume the transfer
                    // For now, just log
                }
            }
        }
    }

    fn show_toast_notification(info: &ipc::TransferInfo) {
        // Windows toast notification for transfer progress
        // This is a simplified version - in production, use windows-toast or similar crate
        let status = match info.status.as_str() {
            "completed" => "Completed",
            "cancelled" => "Cancelled",
            "paused" => "Paused",
            _ => "In Progress",
        };
        
        let title = format!("Connect - File Transfer");
        let body = format!("{} - {}% ({})", info.file_name, 
            (info.transferred_bytes as f32 / info.total_bytes as f32 * 100.0) as u32,
            status);
        
        tracing::info!("Toast notification: {} - {}", title, body);
        
        // In production, use windows::UI::Notifications::ToastNotificationManager
        // For now, just log
    }

    fn stop(&mut self) -> Result<()> {
        // Signal shutdown
        if let Some(tx) = self.shutdown_tx.take() {
            let _ = tx.try_send(());
        }

        // Stop transfer manager
        self.transfer_manager.shutdown();

        // Stop pipe server
        self.pipe_server = None;

        Ok(())
    }
}

fn define_windows_service() -> Result<()> {
    let config = ServiceConfig::default();
    let mut service = ConnectTransferService::new(config);

    let event_handler = move |control_event| -> ServiceControlHandlerResult {
        match control_event {
            ServiceControl::Stop => {
                tracing::info!("Service stop requested");
                // Note: We can't directly call service.stop() here due to closure limitations
                // In a real implementation, we'd use a shared state
                ServiceControlHandlerResult::NoError
            }
            ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
            _ => ServiceControlHandlerResult::NotImplemented,
        }
    };

    let status_handle = service_control_handler::register("ConnectTransferService", event_handler)?;

    // Update status to running
    status_handle.set_service_status(ServiceStatus {
        service_type: ServiceType::OWN_PROCESS,
        current_state: ServiceState::Running,
        controls_accepted: ServiceControlAccept::STOP,
        exit_code: ServiceExitCode::Win32(0),
        checkpoint: 0,
        wait_hint: Duration::from_secs(0),
    })?;

    // Start the service
    service.start()?;

    // Main service loop
    loop {
        std::thread::sleep(Duration::from_secs(1));
        
        // Check for shutdown signal
        // In a real implementation, we'd use a proper shutdown mechanism
    }
}

fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    
    // Register and run the service
    service_dispatcher::start("ConnectTransferService", ffi::define_windows_service)?;
    
    Ok(())
}

#[cfg(windows)]
mod ffi {
    use super::*;
    use windows_service::service_dispatcher;

    pub fn define_windows_service() -> Result<()> {
        // This is a simplified version - real implementation would use service_control_handler
        // and proper service lifecycle management
        Ok(())
    }
}