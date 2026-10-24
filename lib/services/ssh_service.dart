import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import '../models/router_profile.dart';

class SshService {
  SSHClient? _client;
  SftpClient? _sftp;
  RouterProfile? currentProfile;
  ServerSocket? _modemForwardServer;
  int? forwardedModemLocalPort;

  bool get isConnected => _client != null && !(_client!.isClosed);

  Future<void> connect(RouterProfile profile) async {
    await disconnect();
    currentProfile = profile;

    final socket = await SSHSocket.connect(
      profile.host,
      profile.sshPort,
      timeout: const Duration(seconds: 12),
    );

    _client = SSHClient(
      socket,
      username: profile.username,
      onPasswordRequest: () => profile.password,
    );

    await _client!.authenticated;
  }

  Future<void> disconnect() async {
    await _modemForwardServer?.close();
    _modemForwardServer = null;
    forwardedModemLocalPort = null;
    _sftp?.close();
    _sftp = null;
    _client?.close();
    _client = null;
  }

  /// Eksekusi perintah shell di OpenWrt dan kembalikan output String UTF-8
  Future<String> runCommand(String command) async {
    if (!isConnected) {
      if (currentProfile != null) {
        await connect(currentProfile!);
      } else {
        throw Exception('Belum terhubung ke router OpenWrt.');
      }
    }
    final result = await _client!.run(command);
    return utf8.decode(result, allowMalformed: true).trim();
  }

  /// Eksekusi perintah shell secara streaming (Real-Time baris demi baris untuk Live Speedtest)
  Stream<String> runCommandStream(String command) async* {
    if (!isConnected) {
      if (currentProfile != null) {
        await connect(currentProfile!);
      } else {
        throw Exception('Belum terhubung ke router OpenWrt.');
      }
    }
    final session = await _client!.execute(command);
    await for (final chunk in session.stdout) {
      yield utf8.decode(chunk, allowMalformed: true);
    }
  }

  /// Panggil ubus dan parse hasilnya sebagai Map/List JSON
  Future<dynamic> ubusCall(String path, String method, [Map<String, dynamic>? args]) async {
    final argStr = args != null ? "'${json.encode(args)}'" : "'{}'";
    final raw = await runCommand('ubus call $path $method $argStr 2>/dev/null');
    if (raw.isEmpty) return {};
    try {
      return json.decode(raw);
    } catch (_) {
      return {};
    }
  }

  /// Buat sesi Shell PTY interaktif untuk Terminal ala JuiceSSH
  Future<SSHSession> createShell({int width = 80, int height = 25}) async {
    if (!isConnected && currentProfile != null) {
      await connect(currentProfile!);
    }
    return await _client!.shell(
      pty: SSHPtyConfig(width: width, height: height, type: 'xterm-256color'),
    );
  }

  /// Inisialisasi SFTP untuk akses penuh seluruh direktori (/)
  Future<SftpClient> getSftp() async {
    if (!isConnected && currentProfile != null) {
      await connect(currentProfile!);
    }
    _sftp ??= await _client!.sftp();
    return _sftp!;
  }

  /// Baca isi file langsung (via SFTP atau cat fallback)
  Future<String> readFile(String remotePath) async {
    try {
      final sftp = await getSftp();
      final file = await sftp.open(remotePath, mode: SftpFileOpenMode.read);
      final bytes = await file.readBytes();
      await file.close();
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return await runCommand("cat '$remotePath'");
    }
  }

  /// Simpan/Tulis isi file ke sembarang direktori di OpenWrt
  Future<void> writeFile(String remotePath, String content) async {
    try {
      final sftp = await getSftp();
      final file = await sftp.open(
        remotePath,
        mode: SftpFileOpenMode.create | SftpFileOpenMode.truncate | SftpFileOpenMode.write,
      );
      await file.writeBytes(Uint8List.fromList(utf8.encode(content)));
      await file.close();
    } catch (_) {
      final encoded = base64.encode(utf8.encode(content));
      await widgetSafeWriteFallback(remotePath, encoded);
    }
  }

  Future<void> widgetSafeWriteFallback(String remotePath, String base64Content) async {
    await runCommand("echo '$base64Content' | base64 -d > '$remotePath'");
  }

  /// Ubah izin file (CHMOD)
  Future<void> chmodFile(String remotePath, String octalPerm) async {
    await runCommand("chmod $octalPerm '$remotePath'");
  }

  /// Rename atau pindahkan file/folder
  Future<void> renameItem(String oldPath, String newPath) async {
    await runCommand("mv '$oldPath' '$newPath'");
  }

  /// Hapus file atau folder
  Future<void> deleteItem(String path, {bool isDirectory = false}) async {
    if (isDirectory) {
      await runCommand("rm -rf '$path'");
    } else {
      await runCommand("rm -f '$path'");
    }
  }

  /// Port Forwarding Lokal ke IP Modem (192.168.8.1) agar bisa dibuka saat remote via Tailscale/Domain
  Future<String> getModemAccessibleUrl() async {
    final modemIp = currentProfile?.modemIp ?? '192.168.8.1';
    if (!isConnected) return 'http://$modemIp';

    try {
      _modemForwardServer ??= await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      forwardedModemLocalPort = _modemForwardServer!.port;

      _modemForwardServer!.listen((Socket localSocket) async {
        try {
          final forward = await _client!.forwardLocal(modemIp, 80);
          localSocket.listen(
            (Uint8List data) => forward.sink.add(data),
            onDone: () => forward.close(),
            onError: (_) => forward.close(),
          );
          forward.stream.listen(
            (Uint8List data) => localSocket.add(data),
            onDone: () => localSocket.destroy(),
            onError: (_) => localSocket.destroy(),
          );
        } catch (_) {
          localSocket.destroy();
        }
      });

      return 'http://127.0.0.1:$forwardedModemLocalPort';
    } catch (_) {
      return 'http://$modemIp';
    }
  }
}
