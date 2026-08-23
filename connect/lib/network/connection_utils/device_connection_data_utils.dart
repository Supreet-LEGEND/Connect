class DeviceConnectionInfo {
  final String name;
  final String ip;
  final String platform;
  DateTime lastSeen;

  DeviceConnectionInfo({
    required this.name,
    required this.ip,
    required this.platform,
    required this.lastSeen,
  });
}
