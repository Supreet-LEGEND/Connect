use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use serde::{Deserialize, Serialize};
use crate::ipc::{IpcMessage, IpcResponse, TransferInfo};

pub struct TransferManager {
    transfers: Arc<Mutex<HashMap<String, TransferState>>>,
    // For notification callbacks
    notification_handler: Option<Arc<dyn Fn(&TransferInfo) + Send + Sync>>,
}

#[derive(Debug, Clone)]
struct TransferState {
    info: TransferInfo,
    // Notification registration
    registered_for_notifications: bool,
    // For tracking if this is a background transfer
    is_background: bool,
}

impl TransferManager {
    pub fn new() -> Self {
        Self {
            transfers: Arc::new(Mutex::new(HashMap::new())),
            notification_handler: None,
        }
    }

    pub fn set_notification_handler(&mut self, handler: Arc<dyn Fn(&TransferInfo) + Send + Sync>) {
        self.notification_handler = Some(handler);
    }

    fn notify(&self, info: &TransferInfo) {
        if let Some(handler) = &self.notification_handler {
            handler(info);
        }
    }

    pub fn handle_ipc_message(&self, message: IpcMessage) -> IpcResponse {
        match message {
            IpcMessage::StartTransfer { transfer_id, device_id, file_path, file_size, file_name } => {
                let info = TransferInfo {
                    id: transfer_id.clone(),
                    device_id,
                    file_name,
                    total_bytes: file_size,
                    transferred_bytes: 0,
                    status: "queued".to_string(),
                    speed_bps: 0,
                };
                
                self.transfers.lock().unwrap().insert(transfer_id.clone(), TransferState { 
                    info, 
                    registered_for_notifications: false,
                    is_background: true, // Background service transfers are background by default
                });
                
                // In real implementation, spawn the transfer task here
                // For now, just return success
                IpcResponse::Success {
                    data: serde_json::json!({ "transfer_id": transfer_id }),
                }
            }
            IpcMessage::PauseTransfer { transfer_id } => {
                if let Some(state) = self.transfers.lock().unwrap().get_mut(&transfer_id) {
                    state.info.status = "paused".to_string();
                    self.notify(&state.info);
                    IpcResponse::Success { data: serde_json::json!({}) }
                } else {
                    IpcResponse::Error { message: "Transfer not found".to_string() }
                }
            }
            IpcMessage::ResumeTransfer { transfer_id } => {
                if let Some(state) = self.transfers.lock().unwrap().get_mut(&transfer_id) {
                    state.info.status = "transferring".to_string();
                    self.notify(&state.info);
                    IpcResponse::Success { data: serde_json::json!({}) }
                } else {
                    IpcResponse::Error { message: "Transfer not found".to_string() }
                }
            }
            IpcMessage::CancelTransfer { transfer_id } => {
                if let Some(state) = self.transfers.lock().unwrap().remove(&transfer_id) {
                    state.info.status = "cancelled".to_string();
                    self.notify(&state.info);
                    IpcResponse::Success { data: serde_json::json!({}) }
                } else {
                    IpcResponse::Error { message: "Transfer not found".to_string() }
                }
            }
            IpcMessage::GetStatus { transfer_id } => {
                if let Some(state) = self.transfers.lock().unwrap().get(&transfer_id) {
                    IpcResponse::TransferStatus {
                        transfer_id: state.info.id.clone(),
                        progress: if state.info.total_bytes > 0 {
                            state.info.transferred_bytes as f32 / state.info.total_bytes as f32
                        } else {
                            0.0
                        },
                        speed_bps: state.info.speed_bps,
                        status: state.info.status.clone(),
                    }
                } else {
                    IpcResponse::Error { message: "Transfer not found".to_string() }
                }
            }
            IpcMessage::GetAllTransfers => {
                let transfers: Vec<TransferInfo> = self.transfers
                    .lock()
                    .unwrap()
                    .values()
                    .map(|s| s.info.clone())
                    .collect();
                
                IpcResponse::TransferList { transfers }
            }
            IpcMessage::Shutdown => {
                IpcResponse::Success { data: serde_json::json!({}) }
            }
            // Notification-related messages
            IpcMessage::RegisterForNotifications { transfer_id, file_name, total_size } => {
                if let Some(state) = self.transfers.lock().unwrap().get_mut(&transfer_id) {
                    state.registered_for_notifications = true;
                    state.info.file_name = file_name;
                    state.info.total_bytes = total_size;
                    IpcResponse::Success { data: serde_json::json!({}) }
                } else {
                    IpcResponse::Error { message: "Transfer not found".to_string() }
                }
            }
            IpcMessage::UpdateProgress { transfer_id, progress, speed } => {
                if let Some(state) = self.transfers.lock().unwrap().get_mut(&transfer_id) {
                    state.info.transferred_bytes = (state.info.total_bytes as f32 * progress as f32 / 100.0) as u64;
                    state.info.speed_bps = speed;
                    state.info.status = if progress >= 100 { "completed".to_string() } else { "transferring".to_string() };
                    
                    // Send notification if registered
                    if state.registered_for_notifications {
                        self.notify(&state.info);
                    }
                    
                    IpcResponse::Success { data: serde_json::json!({}) }
                } else {
                    IpcResponse::Error { message: "Transfer not found".to_string() }
                }
            }
            IpcMessage::UnregisterNotifications { transfer_id } => {
                if let Some(state) = self.transfers.lock().unwrap().get_mut(&transfer_id) {
                    state.registered_for_notifications = false;
                    IpcResponse::Success { data: serde_json::json!({}) }
                } else {
                    IpcResponse::Error { message: "Transfer not found".to_string() }
                }
            }
            IpcMessage::AppInForeground { in_foreground } => {
                // Track app foreground state for notification behavior
                // In a real implementation, we'd adjust notification behavior
                IpcResponse::Success { data: serde_json::json!({ "in_foreground": in_foreground }) }
            }
            IpcMessage::ResumeTransfers => {
                // Called on service startup to resume incomplete transfers
                let transfers: Vec<TransferInfo> = self.transfers
                    .lock()
                    .unwrap()
                    .values()
                    .filter(|s| s.info.status == "in_progress" || s.info.status == "paused" || s.info.status == "queued")
                    .map(|s| s.info.clone())
                    .collect();
                
                IpcResponse::TransferList { transfers }
            }
        }
    }

    pub fn shutdown(&self) {
        // Cancel all active transfers
        self.transfers.lock().unwrap().clear();
    }
}