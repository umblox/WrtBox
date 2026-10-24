import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../models/router_profile.dart';
import '../services/ssh_service.dart';

class ToolsVpnModemScreen extends StatefulWidget {
  final SshService ssh;
  final RouterProfile profile;
  final String mode; // 'services', 'cloudflared', 'speedtest', 'modem', 'yacd'

  const ToolsVpnModemScreen({
    super.key,
    required this.ssh,
    required this.profile,
    required this.mode,
  });

  @override
  State<ToolsVpnModemScreen> createState() => _ToolsVpnModemScreenState();
}

class _ToolsVpnModemScreenState extends State<ToolsVpnModemScreen> {
  @override
  Widget build(BuildContext context) {
    switch (widget.mode) {
      case 'cloudflared':
        return _CloudflaredVpnView(ssh: widget.ssh);
      case 'speedtest':
        return _VisualSpeedtestView(ssh: widget.ssh);
      case 'modem':
        return _ModemHubView(ssh: widget.ssh, profile: widget.profile);
      case 'yacd':
        return _UniversalWebBridgePage(
          ssh: widget.ssh,
          profile: widget.profile,
          title: 'Yacd • Mihomo / OpenClash Dashboard',
          customPortAndPath: ':9090/ui/',
        );
      case 'services':
      default:
        return _UniversalIpkServicesView(ssh: widget.ssh, profile: widget.profile);
    }
  }
}

/// ============================================================================
/// 1. UNIVERSAL IPK ENGINE (MENU SERVICES — SATU ALAT UNTUK SEMUA IPK)
/// ============================================================================
class _UniversalIpkServicesView extends StatefulWidget {
  final SshService ssh;
  final RouterProfile profile;

  const _UniversalIpkServicesView({required this.ssh, required this.profile});

  @override
  State<_UniversalIpkServicesView> createState() => _UniversalIpkServicesViewState();
}

class _UniversalIpkServicesViewState extends State<_UniversalIpkServicesView> {
  bool _loading = false;
  String _search = '';
  String _selectedCategory = 'All';
  List<Map<String, dynamic>> _installedApps = [];

  @override
  void initState() {
    super.initState();
    _detectAllInstalledIpks();
  }

  /// Deteksi Otomatis Semua IPK LuCI, Menu JSON, Init Service, & Port Web Khusus
  Future<void> _detectAllInstalledIpks() async {
    if (!mounted) return;
    setState(() => _loading = true);

    try {
      const detectScript = r'''
pkgs=$(opkg list-installed 2>/dev/null | grep '^luci-app-' | awk '{print $1 " " $3}')
if [ -z "$pkgs" ]; then
  pkgs=$(apk info -v 2>/dev/null | grep '^luci-app-')
fi

for line in $pkgs; do
  echo "PKG|$line"
done

for f in /usr/share/luci/menu.d/*.json; do
  [ -f "$f" ] || continue
  base=$(basename "$f" .json)
  paths=$(grep -o '"admin/[^"]*"' "$f" | head -n 3 | tr -d '"' | tr '\n' ',')
  echo "MENU|$base|$paths"
done

for c in /etc/config/*; do
  [ -f "$c" ] || continue
  echo "UCI|$(basename "$c")"
done

for s in /etc/init.d/*; do
  [ -f "$s" ] || continue
  name=$(basename "$s")
  running="0"
  pgrep -f "$name" >/dev/null 2>&1 && running="1"
  echo "INIT|$name|$running"
done
''';

      final raw = await widget.ssh.runCommand(detectScript);
      final Set<String> uciConfigs = {};
      final Map<String, bool> initRunning = {};
      final Map<String, String> menuPaths = {};
      final List<String> luciPkgs = [];

      for (final line in raw.split('\n')) {
        final t = line.trim();
        if (t.startsWith('UCI|')) {
          uciConfigs.add(t.substring(4));
        } else if (t.startsWith('INIT|')) {
          final p = t.split('|');
          if (p.length >= 3) initRunning[p[1]] = p[2] == '1';
        } else if (t.startsWith('MENU|')) {
          final p = t.split('|');
          if (p.length >= 3) menuPaths[p[1]] = p[2];
        } else if (t.startsWith('PKG|')) {
          final pkgName = t.substring(4).split(' ').first;
          if (!luciPkgs.contains(pkgName)) luciPkgs.add(pkgName);
        }
      }

      final Set<String> allKeys = {...luciPkgs, ...menuPaths.keys};
      final List<Map<String, dynamic>> apps = [];

      for (final key in allKeys) {
        final shortName = key.replaceFirst('luci-app-', '');
        final pathsRaw = menuPaths[key] ?? '';
        final firstPath = pathsRaw.split(',').firstWhere((e) => e.isNotEmpty, orElse: () => '');

        String category = 'Services';
        if (firstPath.startsWith('admin/modem') ||
            RegExp(r'modem|3ginfo|sms|atinout|hilink|mmcli').hasMatch(shortName)) {
          category = 'Modem';
        } else if (firstPath.startsWith('admin/vpn') ||
            RegExp(r'cloudflared|wireguard|zerotier|tailscale|openvpn|passwall|openclash|nikki|neko|ssr|v2ray').hasMatch(shortName)) {
          category = 'VPN & Tunnel';
        } else if (firstPath.startsWith('admin/system') ||
            RegExp(r'tinyfm|ttyd|diskman|commands|autoreboot').hasMatch(shortName)) {
          category = 'System';
        } else if (firstPath.startsWith('admin/network') ||
            RegExp(r'sqm|mwan3|upnp|ddns|adblock|pbr').hasMatch(shortName)) {
          category = 'Network';
        }

        String matchedUci = '';
        if (uciConfigs.contains(shortName)) {
          matchedUci = shortName;
        } else {
          for (final u in uciConfigs) {
            if (shortName.contains(u) || u.contains(shortName)) {
              matchedUci = u;
              break;
            }
          }
        }

        String matchedInit = '';
        bool isRunning = false;
        if (initRunning.containsKey(shortName)) {
          matchedInit = shortName;
          isRunning = initRunning[shortName] ?? false;
        } else if (matchedUci.isNotEmpty && initRunning.containsKey(matchedUci)) {
          matchedInit = matchedUci;
          isRunning = initRunning[matchedUci] ?? false;
        }

        final luciRoute = firstPath.isNotEmpty ? '/cgi-bin/luci/$firstPath' : '/cgi-bin/luci/admin/services/$shortName';

        apps.add({
          'pkg': key,
          'title': _formatAppTitle(shortName),
          'shortName': shortName,
          'category': category,
          'luciRoute': luciRoute,
          'uciConfig': matchedUci,
          'initScript': matchedInit,
          'running': isRunning,
        });
      }

      apps.sort((a, b) => a['title'].toString().compareTo(b['title'].toString()));
      setState(() => _installedApps = apps);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _formatAppTitle(String raw) {
    return raw
        .split(RegExp(r'[-_]'))
        .map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }

  void _openIpkMultiTool(Map<String, dynamic> app) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _UniversalIpkMultiOpenerScreen(
          ssh: widget.ssh,
          profile: widget.profile,
          appData: app,
        ),
      ),
    ).then((_) => _detectAllInstalledIpks());
  }

  @override
  Widget build(BuildContext context) {
    final categories = ['All', 'Services', 'VPN & Tunnel', 'Modem', 'System', 'Network'];
    final filtered = _installedApps.where((app) {
      final matchCat = _selectedCategory == 'All' || app['category'] == _selectedCategory;
      final matchSearch = _search.isEmpty ||
          app['title'].toString().toLowerCase().contains(_search.toLowerCase()) ||
          app['pkg'].toString().toLowerCase().contains(_search.toLowerCase());
      return matchCat && matchSearch;
    }).toList();

    return Column(
      children: [
        Container(
          color: const Color(0xFF1B222D),
          padding: const EdgeInsets.all(10),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(
                        hintText: 'Cari IPK terinstal (OpenClash, Nikki, TinyFM, Modem, dll)...',
                        prefixIcon: Icon(Icons.search),
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) => setState(() => _search = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: _loading
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh),
                    tooltip: 'Pindai Ulang Semua IPK',
                    onPressed: _detectAllInstalledIpks,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 32,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: categories.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (ctx, i) {
                    final cat = categories[i];
                    return ChoiceChip(
                      visualDensity: VisualDensity.compact,
                      selected: _selectedCategory == cat,
                      label: Text(cat, style: const TextStyle(fontSize: 11.5)),
                      onSelected: (_) => setState(() => _selectedCategory = cat),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    _loading ? 'Memindai semua IPK yang terinstal di OpenWrt...' : 'Tidak ada paket ditemukan.',
                    style: const TextStyle(color: Colors.white54),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(10),
                  itemCount: filtered.length,
                  itemBuilder: (ctx, idx) {
                    final app = filtered[idx];
                    final hasInit = app['initScript'].toString().isNotEmpty;
                    final running = app['running'] == true;

                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: running ? Colors.teal : const Color(0xFF005C97),
                          child: const Icon(Icons.extension, color: Colors.white, size: 20),
                        ),
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(
                                app['title'].toString(),
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.white12,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                app['category'].toString(),
                                style: const TextStyle(fontSize: 10, color: Colors.lightBlueAccent),
                              ),
                            ),
                          ],
                        ),
                        subtitle: Text(
                          'Paket: ${app['pkg']}'
                          '${app['uciConfig'].toString().isNotEmpty ? ' • UCI: /etc/config/${app['uciConfig']}' : ''}',
                          style: const TextStyle(fontSize: 11.5),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (hasInit)
                              IconButton(
                                icon: Icon(
                                  running ? Icons.restart_alt : Icons.play_arrow,
                                  color: running ? Colors.greenAccent : Colors.white70,
                                ),
                                tooltip: running ? 'Restart Service' : 'Start Service',
                                onPressed: () async {
                                  final init = app['initScript'].toString();
                                  await widget.ssh.runCommand('/etc/init.d/$init restart');
                                  _detectAllInstalledIpks();
                                },
                              ),
                            const Icon(Icons.open_in_new, size: 18, color: Colors.lightBlueAccent),
                          ],
                        ),
                        onTap: () => _openIpkMultiTool(app),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _UniversalIpkMultiOpenerScreen extends StatefulWidget {
  final SshService ssh;
  final RouterProfile profile;
  final Map<String, dynamic> appData;

  const _UniversalIpkMultiOpenerScreen({
    required this.ssh,
    required this.profile,
    required this.appData,
  });

  @override
  State<_UniversalIpkMultiOpenerScreen> createState() => _UniversalIpkMultiOpenerScreenState();
}

class _UniversalIpkMultiOpenerScreenState extends State<_UniversalIpkMultiOpenerScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<Map<String, String>> _uciOptions = [];
  String _serviceLog = '';
  bool _loadingUci = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadUciAndLogs();
  }

  Future<void> _loadUciAndLogs() async {
    setState(() => _loadingUci = true);
    try {
      final cfg = widget.appData['uciConfig'].toString();
      final shortName = widget.appData['shortName'].toString();
      if (cfg.isNotEmpty) {
        final uciLines = await widget.ssh.runCommand("uci show '$cfg' 2>/dev/null");
        final opts = <Map<String, String>>[];
        for (final line in uciLines.split('\n')) {
          if (line.contains('=')) {
            final idx = line.indexOf('=');
            final key = line.substring(0, idx).trim();
            final val = line.substring(idx + 1).trim().replaceAll("'", "");
            opts.add({'key': key, 'val': val});
          }
        }
        _uciOptions = opts;
      }
      final logOut = await widget.ssh.runCommand("logread -e '$shortName' | tail -n 80");
      setState(() => _serviceLog = logOut);
    } finally {
      if (mounted) setState(() => _loadingUci = false);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.appData['title'].toString();
    final route = widget.appData['luciRoute'].toString();
    final initName = widget.appData['initScript'].toString();

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.web_asset, size: 18), text: 'App Interface'),
            Tab(icon: Icon(Icons.tune, size: 18), text: 'Universal UCI Config'),
            Tab(icon: Icon(Icons.play_circle_outline, size: 18), text: 'Service & Log'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          _UniversalWebBridgePage(
            ssh: widget.ssh,
            profile: widget.profile,
            title: title,
            luciPath: route,
          ),
          _buildUniversalUciTab(),
          _buildServiceControlTab(initName),
        ],
      ),
    );
  }

  Widget _buildUniversalUciTab() {
    final cfg = widget.appData['uciConfig'].toString();
    if (_loadingUci) return const Center(child: CircularProgressIndicator());
    if (cfg.isEmpty || _uciOptions.isEmpty) {
      return const Center(
        child: Text('Paket ini tidak memiliki file /etc/config/ atau dikelola penuh via antarmuka Tab 1.'),
      );
    }

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: Colors.black26,
          child: Row(
            children: [
              Text('File: /etc/config/$cfg', style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold)),
              const Spacer(),
              FilledButton.icon(
                icon: const Icon(Icons.save, size: 16),
                label: const Text('Commit & Apply'),
                onPressed: () async {
                  await widget.ssh.runCommand("uci commit '$cfg'");
                  final init = widget.appData['initScript'].toString();
                  if (init.isNotEmpty) {
                    await widget.ssh.runCommand("/etc/init.d/'$init' reload || /etc/init.d/'$init' restart");
                  }
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Konfigurasi $cfg berhasil diterapkan!'), backgroundColor: Colors.green),
                  );
                  _loadUciAndLogs();
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: _uciOptions.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (ctx, i) {
              final opt = _uciOptions[i];
              final k = opt['key']!;
              final v = opt['val']!;
              final isBool = v == '0' || v == '1';

              if (isBool && k.split('.').length >= 3) {
                return SwitchListTile(
                  dense: true,
                  title: Text(k, style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5)),
                  value: v == '1',
                  onChanged: (newVal) async {
                    final strVal = newVal ? '1' : '0';
                    setState(() => _uciOptions[i]['val'] = strVal);
                    await widget.ssh.runCommand("uci set $k='$strVal'");
                  },
                );
              }

              return ListTile(
                dense: true,
                title: Text(k, style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.lightBlueAccent)),
                subtitle: Text(v, style: const TextStyle(fontFamily: 'monospace', fontSize: 13, color: Colors.white)),
                trailing: const Icon(Icons.edit, size: 16),
                onTap: () {
                  final valCtrl = TextEditingController(text: v);
                  showDialog(
                    context: context,
                    builder: (dCtx) => AlertDialog(
                      title: Text(k, style: const TextStyle(fontSize: 14, fontFamily: 'monospace')),
                      content: TextField(controller: valCtrl, autofocus: true),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(dCtx), child: const Text('Batal')),
                        FilledButton(
                          onPressed: () async {
                            final nv = valCtrl.text.trim();
                            setState(() => _uciOptions[i]['val'] = nv);
                            await widget.ssh.runCommand("uci set $k='$nv'");
                            if (dCtx.mounted) Navigator.pop(dCtx);
                          },
                          child: const Text('Set UCI'),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildServiceControlTab(String initName) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (initName.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Initscript: /etc/init.d/$initName', style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: ['start', 'restart', 'reload', 'stop', 'enable', 'disable'].map((act) {
                        return FilledButton.tonal(
                          onPressed: () async {
                            await widget.ssh.runCommand('/etc/init.d/$initName $act');
                            _loadUciAndLogs();
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('/etc/init.d/$initName $act dijalankan.')),
                            );
                          },
                          child: Text(act.toUpperCase(), style: const TextStyle(fontSize: 11.5)),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 10),
          const Text('Log Aktivitas Paket:', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(8)),
              child: SingleChildScrollView(
                child: SelectableText(
                  _serviceLog.isEmpty ? 'Tidak ada entri log terbaru untuk paket ini.' : _serviceLog,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: Colors.greenAccent),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UniversalWebBridgePage extends StatefulWidget {
  final SshService ssh;
  final RouterProfile profile;
  final String title;
  final String? luciPath;
  final String? customPortAndPath;
  final String? directUrl;

  const _UniversalWebBridgePage({
    super.key,
    required this.ssh,
    required this.profile,
    required this.title,
    this.luciPath,
    this.customPortAndPath,
    this.directUrl,
  });

  @override
  State<_UniversalWebBridgePage> createState() => _UniversalWebBridgePageState();
}

class _UniversalWebBridgePageState extends State<_UniversalWebBridgePage> {
  late final WebViewController _controller;
  bool _pageLoading = true;
  bool _framelessMode = true;

  String get _targetUrl {
    if (widget.directUrl != null) return widget.directUrl!;
    if (widget.customPortAndPath != null) {
      return 'http://${widget.profile.host}${widget.customPortAndPath}';
    }
    return '${widget.profile.webBaseUrl}${widget.luciPath ?? '/cgi-bin/luci/'}';
  }

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _pageLoading = true);
          },
          onPageFinished: (_) async {
            await _injectAutoLoginAndFramelessCss();
            if (mounted) setState(() => _pageLoading = false);
          },
        ),
      )
      ..loadRequest(Uri.parse(_targetUrl));
  }

  Future<void> _injectAutoLoginAndFramelessCss() async {
    final user = widget.profile.username.replaceAll("'", "\\'");
    final pass = widget.profile.password.replaceAll("'", "\\'");

    final js = '''
(function() {
  var userField = document.querySelector('input[name="luci_username"]');
  var passField = document.querySelector('input[name="luci_password"]');
  if (userField && passField) {
    userField.value = '$user';
    passField.value = '$pass';
    var form = userField.closest('form');
    if (form) form.submit();
  }
  if ($_framelessMode) {
    var style = document.createElement('style');
    style.innerHTML = 'header, .main-left, #mainmenu, .navbar, footer { display: none !important; } .main-right, #maincontent { width: 100% !important; margin: 0 !important; padding: 6px !important; }';
    document.head.appendChild(style);
  }
})();
''';
    try {
      await _controller.runJavaScript(js);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          color: Colors.black38,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, size: 18),
                onPressed: () async {
                  if (await _controller.canGoBack()) await _controller.goBack();
                },
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: () => _controller.reload(),
              ),
              Expanded(
                child: Text(
                  _targetUrl,
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.white70),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              FilterChip(
                visualDensity: VisualDensity.compact,
                label: const Text('Frameless Mode', style: TextStyle(fontSize: 10.5)),
                selected: _framelessMode,
                onSelected: (v) {
                  setState(() => _framelessMode = v);
                  _controller.reload();
                },
              ),
            ],
          ),
        ),
        if (_pageLoading) const LinearProgressIndicator(minHeight: 2),
        Expanded(child: WebViewWidget(controller: _controller)),
      ],
    );
  }
}

/// ============================================================================
/// 2. VPN: CLOUDFLARE ZERO TRUST TUNNEL (cloudflared)
/// ============================================================================
class _CloudflaredVpnView extends StatefulWidget {
  final SshService ssh;

  const _CloudflaredVpnView({required this.ssh});

  @override
  State<_CloudflaredVpnView> createState() => _CloudflaredVpnViewState();
}

class _CloudflaredVpnViewState extends State<_CloudflaredVpnView> {
  bool _loading = false;
  bool _isInstalled = true;
  bool _isRunning = false;
  bool _enabledConfig = false;
  String _version = '-';
  final TextEditingController _tokenCtrl = TextEditingController();
  String _region = '';
  String _protocol = 'auto';
  String _edgeIpVersion = 'auto';
  String _loglevel = 'info';
  String _logs = '';

  @override
  void initState() {
    super.initState();
    _loadCloudflaredData();
  }

  Future<void> _loadCloudflaredData() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final binCheck = await widget.ssh.runCommand('which cloudflared 2>/dev/null');
      if (binCheck.isEmpty) {
        setState(() => _isInstalled = false);
        return;
      }

      final ver = await widget.ssh.runCommand('cloudflared --version 2>/dev/null | head -n 1');
      final pid = await widget.ssh.runCommand('pgrep -f cloudflared 2>/dev/null');
      final enabled = await widget.ssh.runCommand('uci -q get cloudflared.config.enabled');
      final token = await widget.ssh.runCommand('uci -q get cloudflared.config.token');
      final region = await widget.ssh.runCommand('uci -q get cloudflared.config.region');
      final proto = await widget.ssh.runCommand('uci -q get cloudflared.config.protocol');
      final edgeIp = await widget.ssh.runCommand('uci -q get cloudflared.config.edge_ip_version');
      final level = await widget.ssh.runCommand('uci -q get cloudflared.config.loglevel');
      final logOut = await widget.ssh.runCommand(
        'cat /var/log/cloudflared.log 2>/dev/null | tail -n 80 || logread -e cloudflared | tail -n 80',
      );

      setState(() {
        _isInstalled = true;
        _version = ver.isEmpty ? 'Terinstal' : ver;
        _isRunning = pid.trim().isNotEmpty;
        _enabledConfig = enabled.trim() == '1';
        _tokenCtrl.text = token.trim();
        _region = region.trim();
        _protocol = ['auto', 'http2', 'quic'].contains(proto.trim()) ? proto.trim() : 'auto';
        _edgeIpVersion = ['auto', '4', '6'].contains(edgeIp.trim()) ? edgeIp.trim() : 'auto';
        _loglevel = ['info', 'warn', 'error', 'debug'].contains(level.trim()) ? level.trim() : 'info';
        _logs = logOut;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveAndRestartCloudflared() async {
    setState(() => _loading = true);
    try {
      await widget.ssh.runCommand('uci set cloudflared.config=cloudflared 2>/dev/null || true');
      await widget.ssh.runCommand("uci set cloudflared.config.enabled='${_enabledConfig ? '1' : '0'}'");
      await widget.ssh.runCommand("uci set cloudflared.config.token='${_tokenCtrl.text.trim()}'");
      if (_region.isEmpty) {
        await widget.ssh.runCommand('uci -q delete cloudflared.config.region');
      } else {
        await widget.ssh.runCommand("uci set cloudflared.config.region='$_region'");
      }
      await widget.ssh.runCommand("uci set cloudflared.config.protocol='$_protocol'");
      await widget.ssh.runCommand("uci set cloudflared.config.edge_ip_version='$_edgeIpVersion'");
      await widget.ssh.runCommand("uci set cloudflared.config.loglevel='$_loglevel'");
      await widget.ssh.runCommand('uci commit cloudflared');

      if (_enabledConfig) {
        await widget.ssh.runCommand('/etc/init.d/cloudflared enable && /etc/init.d/cloudflared restart');
      } else {
        await widget.ssh.runCommand('/etc/init.d/cloudflared stop');
      }

      await _loadCloudflaredData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pengaturan Cloudflare Zero Trust Tunnel berhasil disimpan & diterapkan!'),
          backgroundColor: Colors.green,
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _tokenCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInstalled) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 54, color: Colors.orangeAccent),
              const SizedBox(height: 12),
              const Text(
                'Paket cloudflared / luci-app-cloudflared belum terdeteksi di router ini.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                icon: const Icon(Icons.download),
                label: const Text('Instal cloudflared via OPKG Sekarang'),
                onPressed: () async {
                  setState(() => _loading = true);
                  await widget.ssh.runCommand('opkg update && opkg install cloudflared luci-app-cloudflared');
                  _loadCloudflaredData();
                },
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: _isRunning ? Colors.green : Colors.redAccent,
              child: const Icon(Icons.vpn_lock, color: Colors.white),
            ),
            title: Text(
              'Cloudflare Zero Trust Tunnel (${_isRunning ? "RUNNING" : "STOPPED"})',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(_version),
            trailing: IconButton(
              icon: _loading
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
              onPressed: _loadCloudflaredData,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Enable Cloudflare Tunnel', style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: const Text('Jalankan service cloudflared secara otomatis (/etc/config/cloudflared)'),
                  value: _enabledConfig,
                  onChanged: (v) => setState(() => _enabledConfig = v),
                ),
                const Divider(),
                TextField(
                  controller: _tokenCtrl,
                  maxLines: 3,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: 'Tunnel Token (Connector Token dari Dashboard Zero Trust)',
                    hintText: 'eyJhIjoi...',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _protocol,
                        decoration: const InputDecoration(labelText: 'Protocol', border: OutlineInputBorder()),
                        items: const [
                          DropdownMenuItem(value: 'auto', child: Text('auto')),
                          DropdownMenuItem(value: 'http2', child: Text('http2')),
                          DropdownMenuItem(value: 'quic', child: Text('quic')),
                        ],
                        onChanged: (v) => setState(() => _protocol = v ?? 'auto'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _edgeIpVersion,
                        decoration: const InputDecoration(labelText: 'Edge IP Version', border: OutlineInputBorder()),
                        items: const [
                          DropdownMenuItem(value: 'auto', child: Text('auto')),
                          DropdownMenuItem(value: '4', child: Text('IPv4 Only')),
                          DropdownMenuItem(value: '6', child: Text('IPv6 Only')),
                        ],
                        onChanged: (v) => setState(() => _edgeIpVersion = v ?? 'auto'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: ['', 'us'].contains(_region) ? _region : '',
                        decoration: const InputDecoration(labelText: 'Region', border: OutlineInputBorder()),
                        items: const [
                          DropdownMenuItem(value: '', child: Text('Global (Default)')),
                          DropdownMenuItem(value: 'us', child: Text('US Only (us)')),
                        ],
                        onChanged: (v) => setState(() => _region = v ?? ''),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _loglevel,
                        decoration: const InputDecoration(labelText: 'Log Level', border: OutlineInputBorder()),
                        items: const [
                          DropdownMenuItem(value: 'info', child: Text('Info')),
                          DropdownMenuItem(value: 'warn', child: Text('Warn')),
                          DropdownMenuItem(value: 'error', child: Text('Error')),
                          DropdownMenuItem(value: 'debug', child: Text('Debug')),
                        ],
                        onChanged: (v) => setState(() => _loglevel = v ?? 'info'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.stop_circle_outlined, color: Colors.redAccent),
                      label: const Text('STOP'),
                      onPressed: () async {
                        await widget.ssh.runCommand('/etc/init.d/cloudflared stop');
                        _loadCloudflaredData();
                      },
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      icon: const Icon(Icons.save),
                      label: const Text('SAVE & APPLY'),
                      onPressed: _loading ? null : _saveAndRestartCloudflared,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Cloudflared Live Logs:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  height: 220,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(8)),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _logs.isEmpty ? 'Belum ada log cloudflared.' : _logs,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: Colors.greenAccent),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// ============================================================================
/// 3. FITUR KHUSUS SPEEDTEST VISUAL (DI ATAS CLI OPENWRT)
/// ============================================================================
class _VisualSpeedtestView extends StatefulWidget {
  final SshService ssh;

  const _VisualSpeedtestView({required this.ssh});

  @override
  State<_VisualSpeedtestView> createState() => _VisualSpeedtestViewState();
}

class _VisualSpeedtestViewState extends State<_VisualSpeedtestView> {
  bool _running = false;
  String _detectedBinary = 'Mendeteksi...';
  String _stageText = 'Siap menjalankan Speedtest langsung dari router OpenWrt';
  double _currentGaugeMbps = 0.0;
  double _pingMs = 0.0;
  double _downloadMbps = 0.0;
  double _uploadMbps = 0.0;
  String _ispInfo = '-';
  final List<Map<String, String>> _history = [];

  @override
  void initState() {
    super.initState();
    _detectSpeedtestCli();
  }

  Future<void> _detectSpeedtestCli() async {
    final check = await widget.ssh.runCommand('''
if which speedtest >/dev/null 2>&1; then echo "speedtest (Ookla)";
elif which speedtest-cli >/dev/null 2>&1; then echo "speedtest-cli (Python)";
elif which librespeed-cli >/dev/null 2>&1; then echo "librespeed-cli";
else echo "curl-cloudflare (Built-in Fallback)"; fi
''');
    if (mounted) setState(() => _detectedBinary = check.trim());
  }

  Future<void> _startSpeedtest() async {
    if (_running) return;
    setState(() {
      _running = true;
      _pingMs = 0;
      _downloadMbps = 0;
      _uploadMbps = 0;
      _currentGaugeMbps = 0;
      _stageText = 'Mengukur Ping & IP Publik ISP...';
    });

    try {
      final ipJson = await widget.ssh.runCommand('curl -s --max-time 6 https://ipinfo.io/json');
      try {
        final map = json.decode(ipJson);
        _ispInfo = '${map['ip'] ?? ''} • ${map['org'] ?? map['isp'] ?? ''} (${map['city'] ?? ''})';
      } catch (_) {}

      if (_detectedBinary.contains('Ookla')) {
        setState(() => _stageText = 'Menjalankan Ookla Speedtest CLI di OpenWrt...');
        final out = await widget.ssh.runCommand(
          'speedtest --accept-license --accept-gdpr -f json 2>/dev/null || speedtest --json 2>/dev/null',
        );
        if (out.isNotEmpty && out.startsWith('{')) {
          final data = json.decode(out);
          final ping = (data['ping']?['latency'] ?? 0).toDouble();
          final dl = ((data['download']?['bandwidth'] ?? 0) * 8 / 1000000).toDouble();
          final ul = ((data['upload']?['bandwidth'] ?? 0) * 8 / 1000000).toDouble();
          setState(() {
            _pingMs = ping;
            _downloadMbps = dl;
            _uploadMbps = ul;
            _currentGaugeMbps = dl;
            _stageText = 'Speedtest selesai (via Ookla CLI)';
          });
          _recordHistory();
          return;
        }
      } else if (_detectedBinary.contains('speedtest-cli') || _detectedBinary.contains('librespeed')) {
        setState(() => _stageText = 'Menjalankan $_detectedBinary di OpenWrt...');
        final cmd = _detectedBinary.contains('librespeed') ? 'librespeed-cli --json' : 'speedtest-cli --json';
        final out = await widget.ssh.runCommand('$cmd 2>/dev/null');
        if (out.isNotEmpty) {
          final decoded = json.decode(out);
          final map = decoded is List ? decoded.first : decoded;
          final ping = (map['ping'] ?? 0).toDouble();
          final dlRaw = (map['download'] ?? 0).toDouble();
          final ulRaw = (map['upload'] ?? 0).toDouble();
          final dl = dlRaw > 10000 ? dlRaw / 1000000 : dlRaw;
          final ul = ulRaw > 10000 ? ulRaw / 1000000 : ulRaw;
          setState(() {
            _pingMs = ping;
            _downloadMbps = dl;
            _uploadMbps = ul;
            _currentGaugeMbps = dl;
            _stageText = 'Speedtest selesai (via $_detectedBinary)';
          });
          _recordHistory();
          return;
        }
      }

      final pingRaw = await widget.ssh.runCommand(
        "ping -c 4 1.1.1.1 2>/dev/null | tail -n 1 | awk -F '/' '{print \$5}'",
      );
      _pingMs = double.tryParse(pingRaw.trim()) ?? 25.0;

      setState(() => _stageText = 'Menguji Kecepatan Download (Cloudflare 25MB)...');
      final dlSpeedBps = await widget.ssh.runCommand(
        "curl -s -o /dev/null -w '%{speed_download}' --max-time 12 'https://speed.cloudflare.com/__down?bytes=25000000'",
      );
      final dlBytesPerSec = double.tryParse(dlSpeedBps.trim()) ?? 0.0;
      _downloadMbps = (dlBytesPerSec * 8) / 1000000;
      setState(() => _currentGaugeMbps = _downloadMbps);

      setState(() => _stageText = 'Menguji Kecepatan Upload...');
      final ulSpeedBps = await widget.ssh.runCommand(
        "dd if=/dev/zero bs=1M count=4 2>/dev/null | curl -s -o /dev/null -w '%{speed_upload}' --max-time 10 -X POST --data-binary @- 'https://speed.cloudflare.com/__up'",
      );
      final ulBytesPerSec = double.tryParse(ulSpeedBps.trim()) ?? 0.0;
      _uploadMbps = (ulBytesPerSec * 8) / 1000000;
      setState(() {
        _currentGaugeMbps = _downloadMbps;
        _stageText = 'Speedtest Selesai!';
      });
      _recordHistory();
    } catch (e) {
      setState(() => _stageText = 'Gagal menyelesaikan speedtest: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _recordHistory() {
    _history.insert(0, {
      'time': TimeOfDay.now().format(context),
      'ping': '${_pingMs.toStringAsFixed(1)} ms',
      'dl': '${_downloadMbps.toStringAsFixed(2)} Mbps',
      'ul': '${_uploadMbps.toStringAsFixed(2)} Mbps',
      'isp': _ispInfo,
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Engine: $_detectedBinary', style: const TextStyle(fontSize: 12, color: Colors.lightBlueAccent)),
                    Flexible(
                      child: Text(
                        _ispInfo,
                        style: const TextStyle(fontSize: 11, color: Colors.white70),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: 220,
                  height: 135,
                  child: CustomPaint(
                    painter: _SpeedGaugePainter(mbps: _currentGaugeMbps),
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _currentGaugeMbps.toStringAsFixed(2),
                            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
                          ),
                          const Text('Mbps', style: TextStyle(fontSize: 12, color: Colors.white60)),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(_stageText, style: const TextStyle(fontSize: 12.5, color: Colors.white70)),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _metricTile('PING', '${_pingMs.toStringAsFixed(1)} ms', Icons.timer_outlined, Colors.amberAccent),
                    _metricTile('DOWNLOAD', '${_downloadMbps.toStringAsFixed(2)} Mbps', Icons.download, Colors.greenAccent),
                    _metricTile('UPLOAD', '${_uploadMbps.toStringAsFixed(2)} Mbps', Icons.upload, Colors.lightBlueAccent),
                  ],
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: 200,
                  height: 44,
                  child: FilledButton.icon(
                    onPressed: _running ? null : _startSpeedtest,
                    icon: _running
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.speed),
                    label: Text(_running ? 'MENGUJI...' : 'MULAI SPEEDTEST'),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_history.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('Riwayat Hasil Speedtest:', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          ..._history.map(
            (h) => Card(
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.history, color: Colors.tealAccent),
                title: Text('DL: ${h['dl']}  •  UL: ${h['ul']}  •  Ping: ${h['ping']}'),
                subtitle: Text('${h['time']} — ${h['isp']}'),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _metricTile(String label, String value, IconData icon, Color color) {
    return Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(fontSize: 11, color: Colors.white60)),
          ],
        ),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }
}

class _SpeedGaugePainter extends CustomPainter {
  final double mbps;
  _SpeedGaugePainter({required this.mbps});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height - 10);
    final radius = size.width / 2 - 12;

    final bgPaint = Paint()
      ..color = Colors.white12
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      math.pi,
      math.pi,
      false,
      bgPaint,
    );

    final normalized = (mbps / 200.0).clamp(0.0, 1.0);
    final activePaint = Paint()
      ..shader = const LinearGradient(colors: [Colors.tealAccent, Colors.lightBlueAccent, Colors.purpleAccent])
          .createShader(Rect.fromCircle(center: center, radius: radius))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      math.pi,
      math.pi * normalized,
      false,
      activePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _SpeedGaugePainter oldDelegate) => oldDelegate.mbps != mbps;
}

/// ============================================================================
/// 4. MENU MODEM HUB (IP KHUSUS MODEM HILINK/RAKITAN + PORT FORWARD + AT COMMAND)
/// ============================================================================
class _ModemHubView extends StatefulWidget {
  final SshService ssh;
  final RouterProfile profile;

  const _ModemHubView({required this.ssh, required this.profile});

  @override
  State<_ModemHubView> createState() => _ModemHubViewState();
}

class _ModemHubViewState extends State<_ModemHubView> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late TextEditingController _modemIpCtrl;
  String? _forwardedUrl;
  String _signalSummary = 'Memuat status sinyal & modem...';
  final TextEditingController _atCmdCtrl = TextEditingController(text: 'AT+CSQ');
  String _atOutput = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _modemIpCtrl = TextEditingController(text: widget.profile.modemIp);
    _initModemData();
  }

  Future<void> _initModemData() async {
    final url = await widget.ssh.getModemAccessibleUrl();
    final sig = await widget.ssh.runCommand('''
mmcli -m 0 2>/dev/null || ubus call network.interface.wan status 2>/dev/null | head -n 25 || ip route show | grep default
''');
    if (mounted) {
      setState(() {
        _forwardedUrl = url;
        _signalSummary = sig.isEmpty ? 'Tidak ada output mmcli/modem.' : sig;
      });
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _modemIpCtrl.dispose();
    _atCmdCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          color: const Color(0xFF1B222D),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.cell_tower, color: Colors.lightBlueAccent),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 36,
                  child: TextField(
                    controller: _modemIpCtrl,
                    decoration: const InputDecoration(
                      labelText: 'IP Khusus Modem (HiLink / Rakitan)',
                      contentPadding: EdgeInsets.symmetric(horizontal: 10),
                      border: OutlineInputBorder(),
                    ),
                    style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                icon: const Icon(Icons.open_in_browser, size: 16),
                label: const Text('Set & Buka IP'),
                onPressed: () async {
                  widget.profile.modemIp = _modemIpCtrl.text.trim();
                  await _initModemData();
                  _tabController.animateTo(0);
                },
              ),
            ],
          ),
        ),
        Container(
          color: Colors.black26,
          child: TabBar(
            controller: _tabController,
            tabs: const [
              Tab(text: 'WebUI Modem (Tab Internal)'),
              Tab(text: 'Sinyal, AT Command & IPK Modem'),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _forwardedUrl == null
                  ? const Center(child: CircularProgressIndicator())
                  : _UniversalWebBridgePage(
                      key: ValueKey(_forwardedUrl),
                      ssh: widget.ssh,
                      profile: widget.profile,
                      title: 'WebUI Modem (${widget.profile.modemIp})',
                      directUrl: _forwardedUrl,
                    ),
              _buildModemToolsTab(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildModemToolsTab() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Aksi Cepat Modem Rakitan & HiLink:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Reconnect WAN / Ganti IP'),
                      onPressed: () async {
                        await widget.ssh.runCommand('ifup wan; ifup wan1; ifup wwan0 2>/dev/null');
                        _initModemData();
                      },
                    ),
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.restart_alt, size: 16),
                      label: const Text('Restart ModemManager'),
                      onPressed: () async {
                        await widget.ssh.runCommand('/etc/init.d/modemmanager restart 2>/dev/null');
                        _initModemData();
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Kirim Perintah AT Command (atinout / sms_tool):', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _atCmdCtrl,
                        decoration: const InputDecoration(
                          labelText: 'AT Command (contoh: AT+CSQ, AT+CPIN?)',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () async {
                        final cmd = _atCmdCtrl.text.trim();
                        final res = await widget.ssh.runCommand(
                          "echo '$cmd' | atinout - /dev/ttyUSB2 - 2>&1 || sms_tool -d /dev/ttyUSB2 at '$cmd' 2>&1",
                        );
                        setState(() => _atOutput = res);
                      },
                      child: const Text('Kirim AT'),
                    ),
                  ],
                ),
                if (_atOutput.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    color: Colors.black87,
                    child: SelectableText(_atOutput, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Informasi Modem & Gateway Aktif:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(8)),
                  child: SelectableText(
                    _signalSummary,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: Colors.greenAccent),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
