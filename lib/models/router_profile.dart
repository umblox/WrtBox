import 'dart:convert';

enum ConnectionType {
  sshAndHttp,   // LAN / Tailscale (SSH + HTTP LuCI)
  sshAndHttps,  // Domain / DDNS / ZeroTrust (SSH + HTTPS LuCI)
  sshTunnelOnly // Remote aman: WebUI & Modem otomatis dilewatkan tunnel SSH
}

class RouterProfile {
  String id;
  String name;
  String host; // Bisa IP Lokal (192.168.1.1), IP Tailscale (100.x.x.x), atau Domain (wrt.domain.com)
  int sshPort;
  int webPort;
  String username;
  String password;
  String modemIp; // Contoh: 192.168.8.1 (HiLink/Rakitan)
  ConnectionType connectionType;

  RouterProfile({
    required this.id,
    required this.name,
    required this.host,
    this.sshPort = 22,
    this.webPort = 80,
    this.username = 'root',
    required this.password,
    this.modemIp = '192.168.8.1',
    this.connectionType = ConnectionType.sshAndHttp,
  });

  String get webBaseUrl {
    final scheme = connectionType == ConnectionType.sshAndHttps ? 'https' : 'http';
    final defaultPort = (scheme == 'https' && webPort == 443) || (scheme == 'http' && webPort == 80);
    return defaultPort ? '$scheme://$host' : '$scheme://$host:$webPort';
  }

  String get connectionBadge {
    if (host.startsWith('100.')) return 'Tailscale';
    if (RegExp(r'^[a-zA-Z]').hasMatch(host)) return 'Domain / Remote';
    return 'Local IP';
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'host': host,
      'sshPort': sshPort,
      'webPort': webPort,
      'username': username,
      'password': password,
      'modemIp': modemIp,
      'connectionType': connectionType.index,
    };
  }

  factory RouterProfile.fromMap(Map<String, dynamic> map) {
    return RouterProfile(
      id: map['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
      name: map['name'] ?? 'OpenWrt Router',
      host: map['host'] ?? '192.168.1.1',
      sshPort: map['sshPort'] ?? 22,
      webPort: map['webPort'] ?? 80,
      username: map['username'] ?? 'root',
      password: map['password'] ?? '',
      modemIp: map['modemIp'] ?? '192.168.8.1',
      connectionType: ConnectionType.values[map['connectionType'] ?? 0],
    );
  }

  String toJson() => json.encode(toMap());
  factory RouterProfile.fromJson(String source) => RouterProfile.fromMap(json.decode(source));
}
