class ConnectionMsgType {
  static const String discoverDevice = "DISCOVER";
  static const String requestConnection = "REQUEST_CONNECTION";
  static const String connectionAccepted = "CONNECTION_ACCEPTED";
  static const String connectionDenied = "CONNECTION_DENIED";
  static const String disconnect = "DISCONNECT";
}

class ConnectionMsgSeparatorType {
  static const String mainSeparator = "|";
  static const String secondarySeparator = "@";
  static const String tertiarySeparator = "^";
}
