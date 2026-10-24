import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/router_profile.dart';
import 'services/ssh_service.dart';
import 'screens/status_screen.dart';
import 'screens/network_screen.dart';
import 'screens/system_maintenance_screen.dart';
import 'screens/file_manager_screen.dart';
import 'screens/terminal_screen.dart';
import 'screens/tools_vpn_modem_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WrtBoxApp());
}

class WrtBoxApp extends StatelessWidget {
  const WrtBoxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WrtBox OpenWrt Manager',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF0088CC),
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF12161F),
      ),
      home: const RouterListScreen(),
    );
  }
}

class RouterListScreen extends StatefulWidget {
  const RouterListScreen({super.key});

  @override
  State<RouterListScreen> createState() => _RouterListScreenState();
}

class _RouterListScreenState extends State<RouterListScreen> {
  final SshService _sshService = SshService();
  List<RouterProfile> _profiles = [];
  bool _isConnecting = false;

  @override
  void initState() {
    super.initState();
    _loadProfiles();
  }

  Future<void> _loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final rawList = prefs.getStringList('saved_routers') ?? [];
    setState(() {
      _profiles = rawList.map((e) => RouterProfile.fromJson(e)).toList();
      if (_profiles.isEmpty) {
        _profiles.add(
          RouterProfile(
            id: 'default',
            name: 'OpenWrt Utama',
            host: '192.168.1.1',
            sshPort: 22,
            webPort: 80,
            username: 'root',
            password: '',
            modemIp: '192.168.8.1',
          ),
        );
      }
    });
  }

  Future<void> _saveProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'saved_routers',
      _profiles.map((e) => e.toJson()).toList(),
    );
  }

  Future<void> _connectToRouter(RouterProfile profile) async {
    setState(() => _isConnecting = true);
    try {
      await _sshService.connect(profile);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MainDashboardShell(ssh: _sshService, profile: profile),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Gagal terhubung ke ${profile.host}:${profile.sshPort} -> $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  void _showDeviceDialog({RouterProfile? existing}) {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final hostCtrl = TextEditingController(text: existing?.host ?? '192.168.1.1');
    final sshPortCtrl = TextEditingController(text: (existing?.sshPort ?? 22).toString());
    final webPortCtrl = TextEditingController(text: (existing?.webPort ?? 80).toString());
    final userCtrl = TextEditingController(text: existing?.username ?? 'root');
    final passCtrl = TextEditingController(text: existing?.password ?? '');
    final modemIpCtrl = TextEditingController(text: existing?.modemIp ?? '192.168.8.1');
    ConnectionType selectedType = existing?.connectionType ?? ConnectionType.sshAndHttp;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'Tambah Device OpenWrt' : 'Edit Device OpenWrt'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Nama Profil (Contoh: STB Rumah / CHR)',
                    prefixIcon: Icon(Icons.router),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: hostCtrl,
                  decoration: const InputDecoration(
                    labelText: 'IP Lokal / IP Tailscale / Domain',
                    helperText: 'Contoh: 192.168.1.1, 100.x.y.z, atau wrt.domain.com',
                    prefixIcon: Icon(Icons.language),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: sshPortCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Port SSH (22)'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: webPortCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Port Web/LuCI (80)'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<ConnectionType>(
                  value: selectedType,
                  decoration: const InputDecoration(labelText: 'Jenis Koneksi'),
                  items: const [
                    DropdownMenuItem(
                      value: ConnectionType.sshAndHttp,
                      child: Text('SSH + HTTP (LAN / Tailscale)'),
                    ),
                    DropdownMenuItem(
                      value: ConnectionType.sshAndHttps,
                      child: Text('SSH + HTTPS (Domain / SSL)'),
                    ),
                    DropdownMenuItem(
                      value: ConnectionType.sshTunnelOnly,
                      child: Text('SSH Tunnel Only (Remote Port-Forward)'),
                    ),
                  ],
                  onChanged: (val) {
                    if (val != null) setDialogState(() => selectedType = val);
                  },
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: userCtrl,
                        decoration: const InputDecoration(labelText: 'Username'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: passCtrl,
                        obscureText: true,
                        decoration: const InputDecoration(labelText: 'Password SSH'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: modemIpCtrl,
                  decoration: const InputDecoration(
                    labelText: 'IP Khusus Modem (HiLink / Rakitan)',
                    helperText: 'Contoh: 192.168.8.1 atau 192.168.1.1',
                    prefixIcon: Icon(Icons.cell_tower),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () {
                final newProfile = RouterProfile(
                  id: existing?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
                  name: nameCtrl.text.trim().isEmpty ? 'OpenWrt' : nameCtrl.text.trim(),
                  host: hostCtrl.text.trim(),
                  sshPort: int.tryParse(sshPortCtrl.text.trim()) ?? 22,
                  webPort: int.tryParse(webPortCtrl.text.trim()) ?? 80,
                  username: userCtrl.text.trim().isEmpty ? 'root' : userCtrl.text.trim(),
                  password: passCtrl.text,
                  modemIp: modemIpCtrl.text.trim().isEmpty ? '192.168.8.1' : modemIpCtrl.text.trim(),
                  connectionType: selectedType,
                );

                setState(() {
                  if (existing == null) {
                    _profiles.add(newProfile);
                  } else {
                    final idx = _profiles.indexWhere((p) => p.id == existing.id);
                    if (idx != -1) _profiles[idx] = newProfile;
                  }
                });
                _saveProfiles();
                Navigator.pop(ctx);
              },
              child: const Text('Simpan'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WrtBox — Winbox for OpenWrt'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: 'Tambah Device',
            onPressed: () => _showDeviceDialog(),
          ),
        ],
      ),
      body: _isConnecting
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Menghubungkan jalur SSH & ubus ke OpenWrt...'),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _profiles.length,
              itemBuilder: (ctx, i) {
                final p = _profiles[i];
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    leading: const CircleAvatar(
                      backgroundColor: Color(0xFF0088CC),
                      child: Icon(Icons.router, color: Colors.white),
                    ),
                    title: Text(
                      p.name,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      '${p.host}:${p.sshPort} (${p.connectionBadge}) • Modem: ${p.modemIp}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit, size: 20),
                          onPressed: () => _showDeviceDialog(existing: p),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
                          onPressed: () {
                            setState(() => _profiles.removeAt(i));
                            _saveProfiles();
                          },
                        ),
                      ],
                    ),
                    onTap: () => _connectToRouter(p),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showDeviceDialog(),
        icon: const Icon(Icons.add),
        label: const Text('Tambah Device'),
      ),
    );
  }
}

/// Kerangka Navigasi Utama setelah terhubung ke Router (Gaya LuCI Alpha + Shortcut Atas)
class MainDashboardShell extends StatefulWidget {
  final SshService ssh;
  final RouterProfile profile;

  const MainDashboardShell({super.key, required this.ssh, required this.profile});

  @override
  State<MainDashboardShell> createState() => _MainDashboardShellState();
}

class _MainDashboardShellState extends State<MainDashboardShell> {
  String _activeMenu = 'status_overview';
  String _title = 'Status • Overview';

  void _selectMenu(String key, String title) {
    setState(() {
      _activeMenu = key;
      _title = title;
    });
  }

  Widget _buildBody() {
    switch (_activeMenu) {
      case 'status_overview':
      case 'status_logs':
      case 'status_processes':
      case 'status_netmon':
        return StatusScreen(ssh: widget.ssh, initialSection: _activeMenu);

      case 'net_interfaces':
        return NetworkScreen(ssh: widget.ssh, initialTab: 0);
      case 'net_devices':
        return NetworkScreen(ssh: widget.ssh, initialTab: 1);
      case 'net_global':
        return NetworkScreen(ssh: widget.ssh, initialTab: 2);

      case 'sys_startup':
        return SystemMaintenanceScreen(ssh: widget.ssh, initialSection: 'startup');
      case 'sys_cron':
        return SystemMaintenanceScreen(ssh: widget.ssh, initialSection: 'cron');
      case 'sys_power':
        return SystemMaintenanceScreen(ssh: widget.ssh, initialSection: 'power');

      case 'file_manager':
        return FileManagerScreen(ssh: widget.ssh);

      case 'terminal':
        return TerminalScreen(ssh: widget.ssh);

      case 'vpn_cloudflared':
        return ToolsVpnModemScreen(
          ssh: widget.ssh,
          profile: widget.profile,
          mode: 'cloudflared',
        );
      case 'modem_hub':
        return ToolsVpnModemScreen(
          ssh: widget.ssh,
          profile: widget.profile,
          mode: 'modem',
        );
      case 'services_ipk':
        return ToolsVpnModemScreen(
          ssh: widget.ssh,
          profile: widget.profile,
          mode: 'services',
        );
      case 'speedtest':
        return ToolsVpnModemScreen(
          ssh: widget.ssh,
          profile: widget.profile,
          mode: 'speedtest',
        );
      case 'yacd':
        return ToolsVpnModemScreen(
          ssh: widget.ssh,
          profile: widget.profile,
          mode: 'yacd',
        );

      default:
        return StatusScreen(ssh: widget.ssh, initialSection: 'status_overview');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(86),
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF005C97), Color(0xFF0099CC)],
            ),
          ),
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Baris Ikon Shortcut Atas (Persis Screenshot: Menu, Clash, Neko/Nikki, Terminal, TinyFM, NetMon, System)
                SizedBox(
                  height: 48,
                  child: Row(
                    children: [
                      Builder(
                        builder: (ctx) => IconButton(
                          icon: const Icon(Icons.menu, color: Colors.white),
                          onPressed: () => Scaffold.of(ctx).openDrawer(),
                        ),
                      ),
                      _topShortcutButton(
                        icon: Icons.pets,
                        tooltip: 'OpenClash / Mihomo',
                        onTap: () => _selectMenu('services_ipk', 'Services • All IPK'),
                      ),
                      _topShortcutButton(
                        icon: Icons.hub,
                        tooltip: 'Nikki / Neko / Tunnel',
                        onTap: () => _selectMenu('vpn_cloudflared', 'VPN & Tunnel'),
                      ),
                      _topShortcutButton(
                        icon: Icons.terminal,
                        tooltip: 'Terminal (JuiceSSH Style)',
                        onTap: () => _selectMenu('terminal', 'Terminal SSH'),
                      ),
                      _topShortcutButton(
                        icon: Icons.folder_open,
                        tooltip: 'Root File Manager (/)',
                        onTap: () => _selectMenu('file_manager', 'System • File Manager'),
                      ),
                      _topShortcutButton(
                        icon: Icons.speed,
                        tooltip: 'Speedtest & Net Monitor',
                        onTap: () => _selectMenu('speedtest', 'Network • Speedtest CLI'),
                      ),
                      _topShortcutButton(
                        icon: Icons.settings,
                        tooltip: 'Startup & Cron',
                        onTap: () => _selectMenu('sys_startup', 'System • Startup'),
                      ),
                      const Spacer(),
                      Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: Text(
                          widget.profile.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Sub-bar Link Cepat: About | Modem | Terminal | Yacd | Speedtest
                Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  color: Colors.black26,
                  child: Row(
                    children: [
                      _quickTextLink('Overview', () => _selectMenu('status_overview', 'Status • Overview')),
                      _quickTextLink('Modem', () => _selectMenu('modem_hub', 'Modem • WebUI & Tools')),
                      _quickTextLink('Terminal', () => _selectMenu('terminal', 'Terminal SSH')),
                      _quickTextLink('Yacd', () => _selectMenu('yacd', 'Yacd Dashboard')),
                      _quickTextLink('Speedtest', () => _selectMenu('speedtest', 'Speedtest CLI')),
                      const Spacer(),
                      Text(
                        _title,
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      drawer: _buildAlphaDrawer(),
      body: _buildBody(),
    );
  }

  Widget _topShortcutButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: const Color(0xFF005C97), size: 22),
        ),
      ),
    );
  }

  Widget _quickTextLink(String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 14),
      child: InkWell(
        onTap: onTap,
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildAlphaDrawer() {
    return Drawer(
      backgroundColor: Colors.white,
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            ExpansionTile(
              title: const Text('Status', style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)),
              initiallyExpanded: true,
              children: [
                _drawerSubItem('Overview & Release RAM', 'status_overview'),
                _drawerSubItem('System & Kernel Log', 'status_logs'),
                _drawerSubItem('Processes', 'status_processes'),
                _drawerSubItem('Traffic & Net Monitor', 'status_netmon'),
              ],
            ),
            ExpansionTile(
              title: const Text('System', style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)),
              children: [
                _drawerSubItem('Startup (Initscripts & rc.local)', 'sys_startup'),
                _drawerSubItem('File Manager (Root /)', 'file_manager'),
                _drawerSubItem('Scheduled Tasks (Cron)', 'sys_cron'),
                _drawerSubItem('Reboot & Shutdown', 'sys_power'),
              ],
            ),
            ExpansionTile(
              title: const Text('Modem', style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)),
              children: [
                _drawerSubItem('Modem WebUI & IPK Rakitan', 'modem_hub'),
                _drawerSubItem('Speedtest Visual (CLI)', 'speedtest'),
              ],
            ),
            ExpansionTile(
              title: const Text('Services', style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)),
              children: [
                _drawerSubItem('Semua IPK Terinstal (Auto-Detect)', 'services_ipk'),
                _drawerSubItem('Yacd / Clash Panel', 'yacd'),
                _drawerSubItem('Terminal (JuiceSSH Mode)', 'terminal'),
              ],
            ),
            ExpansionTile(
              title: const Text('Network', style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)),
              children: [
                _drawerSubItem('Interfaces', 'net_interfaces'),
                _drawerSubItem('Devices (MTU & Bridge)', 'net_devices'),
                _drawerSubItem('Global network options', 'net_global'),
              ],
            ),
            ExpansionTile(
              title: const Text('VPN', style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)),
              children: [
                _drawerSubItem('Cloudflare Zero Trust Tunnel', 'vpn_cloudflared'),
              ],
            ),
            const Divider(color: Colors.black26),
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.black87),
              title: const Text('Log out', style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)),
              onTap: () async {
                await widget.ssh.disconnect();
                if (!mounted) return;
                Navigator.pop(context);
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _drawerSubItem(String label, String key) {
    final selected = _activeMenu == key;
    return ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: const Color(0xFF0077B5),
      title: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : Colors.black87,
            fontSize: 13,
          ),
        ),
      ),
      onTap: () {
        Navigator.pop(context);
        _selectMenu(key, label);
      },
    );
  }
}
