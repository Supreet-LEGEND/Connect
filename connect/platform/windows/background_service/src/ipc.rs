use std::io::{Read, Write};
use std::os::windows::io::AsRawHandle;
use std::sync::Arc;
use tokio::sync::mpsc;
use windows::Win32::Foundation::*;
use windows::Win32::Storage::FileSystem::*;
use windows::Win32::System::Pipes::*;
use windows::Win32::System::IO::*;
use serde::{Deserialize, Serialize};
use anyhow::Result;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum IpcMessage {
    StartTransfer {
        transfer_id: String,
        device_id: String,
        file_path: String,
        file_size: u64,
        file_name: String,
    },
    PauseTransfer {
        transfer_id: String,
    },
    ResumeTransfer {
        transfer_id: String,
    },
    CancelTransfer {
        transfer_id: String,
    },
    GetStatus {
        transfer_id: String,
    },
    GetAllTransfers,
    Shutdown,
    // Notification-related messages
    RegisterForNotifications {
        transfer_id: String,
        file_name: String,
        total_size: u64,
    },
    UpdateProgress {
        transfer_id: String,
        progress: u32,
        speed: u64,
    },
    UnregisterNotifications {
        transfer_id: String,
    },
    // App lifecycle
    AppInForeground {
        in_foreground: bool,
    },
    // Resume transfers on boot
    ResumeTransfers,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum IpcResponse {
    Success { data: serde_json::Value },
    Error { message: String },
    TransferStatus {
        transfer_id: String,
        progress: f32,
        speed_bps: u64,
        status: String,
    },
    TransferList { transfers: Vec<TransferInfo> },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransferInfo {
    pub id: String,
    pub device_id: String,
    pub file_name: String,
    pub total_bytes: u64,
    pub transferred_bytes: u64,
    pub status: String,
    pub speed_bps: u64,
}

pub struct NamedPipeServer {
    pipe_name: String,
    handler: Arc<dyn Fn(IpcMessage) -> IpcResponse + Send + Sync>,
}

impl NamedPipeServer {
    pub fn new<F>(pipe_name: String, handler: F) -> Self
    where
        F: Fn(IpcMessage) -> IpcResponse + Send + Sync + 'static,
    {
        Self {
            pipe_name,
            handler: Arc::new(handler),
        }
    }

    pub async fn run(&self) {
        loop {
            // Create named pipe instance
            let pipe_name = format!(r"\\.\pipe\{}", self.pipe_name);
            
            let pipe_handle = unsafe {
                CreateNamedPipeW(
                    &HSTRING::from(pipe_name),
                    PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
                    PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
                    PIPE_UNLIMITED_INSTANCES,
                    4096,
                    4096,
                    0,
                    None,
                )
            };

            if pipe_handle.is_invalid() {
                tracing::error!("Failed to create named pipe");
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                continue;
            }

            // Wait for connection
            let connected = unsafe { ConnectNamedPipe(pipe_handle, None) };
            
            if connected.as_bool() || unsafe { GetLastError() }.0 == ERROR_PIPE_CONNECTED.0 {
                let handler = self.handler.clone();
                let pipe_handle_clone = pipe_handle;
                
                tokio::task::spawn_blocking(move || {
                    Self::handle_client(pipe_handle_clone, handler);
                });
            } else {
                unsafe { CloseHandle(pipe_handle) };
            }
        }
    }

    fn handle_client(pipe_handle: HANDLE, handler: Arc<dyn Fn(IpcMessage) -> IpcResponse + Send + Sync>) {
        let mut buffer = [0u8; 4096];
        
        loop {
            let mut bytes_read = 0u32;
            let result = unsafe {
                ReadFile(
                    pipe_handle,
                    Some(&mut buffer),
                    Some(&mut bytes_read),
                    None,
                )
            };

            if !result.as_bool() || bytes_read == 0 {
                break;
            }

            let message_bytes = &buffer[..bytes_read as usize];
            
            // Parse message
            if let Ok(message) = serde_json::from_slice::<IpcMessage>(message_bytes) {
                let response = handler(message);
                
                // Send response
                if let Ok(response_bytes) = serde_json::to_vec(&response) {
                    let mut bytes_written = 0u32;
                    unsafe {
                        WriteFile(
                            pipe_handle,
                            Some(&response_bytes),
                            Some(&mut bytes_written),
                            None,
                        )
                    };
                }
            }
        }

        unsafe { CloseHandle(pipe_handle) };
    }
}

pub struct NamedPipeClient {
    pipe_name: String,
    handle: Option<HANDLE>,
}

impl NamedPipeClient {
    pub fn new(pipe_name: String) -> Self {
        Self {
            pipe_name: format!(r"\\.\pipe\{}", pipe_name),
            handle: None,
        }
    }

    pub fn connect(&mut self) -> Result<()> {
        let handle = unsafe {
            CreateFileW(
                &HSTRING::from(&self.pipe_name),
                GENERIC_READ.0 | GENERIC_WRITE.0,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                None,
                OPEN_EXISTING,
                FILE_FLAG_OVERLAPPED,
                None,
            )
        };

        if handle.is_invalid() {
            return Err(anyhow::anyhow!("Failed to connect to named pipe"));
        }

        self.handle = Some(handle);
        Ok(())
    }

    pub fn send(&self, message: &IpcMessage) -> Result<IpcResponse> {
        let handle = self.handle.ok_or_else(|| anyhow::anyhow!("Not connected"))?;
        
        let request_bytes = serde_json::to_vec(message)?;
        
        let mut bytes_written = 0u32;
        unsafe {
            WriteFile(
                handle,
                Some(&request_bytes),
                Some(&mut bytes_written),
                None,
            )
        };

        // Read response
        let mut buffer = [0u8; 4096];
        let mut bytes_read = 0u32;
        unsafe {
            ReadFile(
                handle,
                Some(&mut buffer),
                Some(&mut bytes_read),
                None,
            )
        };

        let response_bytes = &buffer[..bytes_read as usize];
        let response = serde_json::from_slice(response_bytes)?;
        
        Ok(response)
    }

    pub fn disconnect(&mut self) {
        if let Some(handle) = self.handle.take() {
            unsafe { CloseHandle(handle) };
        }
    }
}