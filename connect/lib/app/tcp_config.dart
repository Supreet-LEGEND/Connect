class BaseTcpConfig {
  static const int noOfActiveSockets = 6;
  static const int maxNoOfConnectedDevices = 2;
  static const int fileChunkSize = 1024 * 1024; // 1 MB
  static const int bufferSize = 1024 * 8; // 8 KB
  static const int tcpPort = 4040;
  static const String saltStr = 'connect-app-v1';
}
