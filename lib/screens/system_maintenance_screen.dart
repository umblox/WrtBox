import 'package:flutter/material.dart';
import '../services/ssh_service.dart';

class SystemMaintenanceScreen extends StatefulWidget {
  final SshService ssh;
  final String initialSection; // 'startup', 'cron', 'power'

  const SystemMaintenanceScreen({
    super.key,
    required this.ssh,
    this.initialSection = 'startup',
  });

  @override
  State<SystemMaintenanceScreen> createState() => _SystemMaintenanceScreenState();
}

class _SystemMaintenanceScreenState extends State<SystemMaintenanceScreen>
    with SingleTickerProviderStateMixin {
  late TabController _mainTabController;
  bool _loading = false;

  // Startup: Initscripts & Local Startup (/etc/rc.local)
  List<Map<String, dynamic>> _initScripts = [];
  String _initSearch = '';
  final TextEditingController _rcLocalCtrl = TextEditingController();

  // Cron (/etc/crontabs/root)
  final TextEditingController _cronCodeCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    int idx = 0;
    if (widget.initialSection == 'cron') idx = 1;
    if (widget.initialSection == 'power') idx = 2;

    _mainTabController = TabController(length: 3, vsync: this, initialIndex: idx);
    _mainTabController.addListener(() {
      if (!_mainTabController.indexIsChanging) _loadCurrentTab();
    });
    _loadCurrentTab();
  }

  @override
  void didUpdateWidget(covariant SystemMaintenanceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialSection != widget.initialSection) {
      int idx = 0;
      if (widget.initialSection == 'cron') idx = 1;
      if (widget.initialSection == 'power') idx = 2;
      _mainTabController.animateTo(idx);
      _loadCurrentTab();
    }
  }

  Future<void> _loadCurrentTab() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      if (_mainTabController.index == 0) {
        await Future.wait([_detectInitScripts(), _loadRcLocal()]);
      } else if (_mainTabController.index == 1) {
        await _loadCrontab();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal memuat data System: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Deteksi Dinamis Seluruh Initscripts (/etc/init.d/*) beserta Start Priority & Status Enabled
  Future<void> _detectInitScripts() async {
    const cmd = r'''
for f in /etc/init.d/*; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  prio=$(grep -m1 '^START=' "$f" 2>/dev/null | cut -d= -f2 | tr -d '"'\'' ')
  [ -z "$prio" ] && prio="99"
  enabled="0"
  ls /etc/rc.d/S*"$name" >/dev/null 2>&1 && enabled="1"
  echo "$prio|$name|$enabled"
done
''';
    final raw = await widget.ssh.runCommand(cmd);
    final List<Map<String, dynamic>> list = [];

    for (final line in raw.split('\n')) {
      final parts = line.trim().split('|');
      if (parts.length == 3) {
        final pNum = int.tryParse(parts[0]) ?? 99;
        list.add({
          'priority': pNum.toString().padLeft(2, '0'),
          'sortKey': pNum,
          'name': parts[1],
          'enabled': parts[2] == '1',
        });
      }
    }

    list.sort((a, b) {
      final cmp = (a['sortKey'] as int).compareTo(b['sortKey'] as int);
      if (cmp != 0) return cmp;
      return a['name'].toString().compareTo(b['name'].toString());
    });

    setState(() => _initScripts = list);
  }

  Future<void> _runInitAction(String scriptName, String action) async {
    setState(() => _loading = true);
    try {
      await widget.ssh.runCommand('/etc/init.d/$scriptName $action');
      await _detectInitScripts();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Initscript "$scriptName" -> $action selesai.')),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadRcLocal() async {
    final content = await widget.ssh.readFile('/etc/rc.local');
    setState(() => _rcLocalCtrl.text = content);
  }

  Future<void> _saveRcLocal() async {
    setState(() => _loading = true);
    try {
      await widget.ssh.writeFile('/etc/rc.local', _rcLocalCtrl.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('/etc/rc.local berhasil disimpan (SAVE)!'),
          backgroundColor: Colors.green,
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadCrontab() async {
    final content = await widget.ssh.runCommand('cat /etc/crontabs/root 2>/dev/null || true');
    setState(() => _cronCodeCtrl.text = content);
  }

  Future<void> _saveCrontab() async {
    setState(() => _loading = true);
    try {
      String text = _cronCodeCtrl.text;
      if (text.isNotEmpty && !text.endsWith('\n')) {
        text += '\n';
      }
      await widget.ssh.writeFile('/etc/crontabs/root', text);
      await widget.ssh.runCommand('/etc/init.d/cron restart');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Scheduled Tasks (Cron) berhasil disimpan & diaktifkan!'),
          backgroundColor: Colors.green,
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _mainTabController.dispose();
    _rcLocalCtrl.dispose();
    _cronCodeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          color: const Color(0xFF1B222D),
          child: Row(
            children: [
              Expanded(
                child: TabBar(
                  controller: _mainTabController,
                  isScrollable: true,
                  tabs: const [
                    Tab(text: 'Startup (Initscripts & rc.local)'),
                    Tab(text: 'Scheduled Tasks (Cron)'),
                    Tab(text: 'Reboot & Shutdown'),
                  ],
                ),
              ),
              IconButton(
                icon: _loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                onPressed: _loadCurrentTab,
              ),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _mainTabController,
            children: [
              _buildStartupSection(),
              _buildCronSection(),
              _buildPowerSection(),
            ],
          ),
        ),
      ],
    );
  }

  /// SUB-TAB STARTUP: Initscripts & Local Startup
  Widget _buildStartupSection() {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Container(
            color: Colors.black26,
            child: const TabBar(
              tabs: [
                Tab(text: 'Initscripts'),
                Tab(text: 'Local Startup'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                _buildInitscriptsSubTab(),
                _buildLocalStartupSubTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInitscriptsSubTab() {
    final filtered = _initScripts.where((s) {
      if (_initSearch.isEmpty) return true;
      return s['name'].toString().toLowerCase().contains(_initSearch.toLowerCase());
    }).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Cari Initscript (contoh: openclash, nikki, tailscale, modemmanager)...',
              prefixIcon: Icon(Icons.search),
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _initSearch = v),
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            itemCount: filtered.length,
            separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
            itemBuilder: (ctx, i) {
              final item = filtered[i];
              final name = item['name'].toString();
              final prio = item['priority'].toString();
              final enabled = item['enabled'] == true;

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        SizedBox(
                          width: 95,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Start priority',
                                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Colors.white60),
                              ),
                              Text(prio, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Initscript',
                                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Colors.white60),
                              ),
                              Text(name, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // 5 Tombol Persis Screenshot: ENABLED/DISABLED | START | RESTART | RELOAD | STOP
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _initBtn(
                            label: enabled ? 'ENABLED' : 'DISABLED',
                            color: enabled ? const Color(0xFF1D78A8) : const Color(0xFF9E1C1C),
                            onTap: () => _runInitAction(name, enabled ? 'disable' : 'enable'),
                          ),
                          const SizedBox(width: 6),
                          _initBtn(
                            label: 'START',
                            color: const Color(0xFF1D78A8),
                            onTap: () => _runInitAction(name, 'start'),
                          ),
                          const SizedBox(width: 6),
                          _initBtn(
                            label: 'RESTART',
                            color: const Color(0xFF1D78A8),
                            onTap: () => _runInitAction(name, 'restart'),
                          ),
                          const SizedBox(width: 6),
                          _initBtn(
                            label: 'RELOAD',
                            color: const Color(0xFF1D78A8),
                            onTap: () => _runInitAction(name, 'reload'),
                          ),
                          const SizedBox(width: 6),
                          _initBtn(
                            label: 'STOP',
                            color: const Color(0xFF1D78A8),
                            onTap: () => _runInitAction(name, 'stop'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _initBtn({required String label, required Color color, required VoidCallback onTap}) {
    return SizedBox(
      height: 28,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        onPressed: _loading ? null : onTap,
        child: Text(label, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold)),
      ),
    );
  }

  /// SUB-TAB LOCAL STARTUP (/etc/rc.local)
  Widget _buildLocalStartupSubTab() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "This is the content of /etc/rc.local. Insert your own commands here (in front of 'exit 0') to execute them at the end of the boot process.",
            style: TextStyle(fontSize: 12, color: Colors.white70),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: TextField(
              controller: _rcLocalCtrl,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(
                filled: true,
                fillColor: Colors.black54,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1D78A8)),
              onPressed: _loading ? null : _saveRcLocal,
              child: const Text('SAVE', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  /// TAB SCHEDULED TASKS (CRON): Deteksi Otomatis + Tambah/Edit/Hapus Baris + 1 Tombol SAVE
  Widget _buildCronSection() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This is the system crontab (/etc/crontabs/root) in which scheduled tasks can be defined.',
            style: TextStyle(fontSize: 12, color: Colors.white70),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Tambah Baris Cron'),
                onPressed: () => _showCronHelperDialog(),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.list_alt, size: 16),
                label: const Text('Edit / Hapus per Baris'),
                onPressed: () => _showCronLinesManagerDialog(),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: TextField(
              controller: _cronCodeCtrl,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(
                hintText: '# Contoh:\n# 0 4 * * * reboot\n# */5 * * * * /usr/bin/modem_watchdog.sh',
                filled: true,
                fillColor: Colors.black54,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1D78A8)),
              onPressed: _loading ? null : _saveCrontab,
              child: const Text('SAVE', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  void _showCronHelperDialog({int? editIndex, String? initialLine}) {
    String sched = '0 4 * * *';
    String cmd = 'reboot';
    if (initialLine != null && initialLine.trim().isNotEmpty && !initialLine.trim().startsWith('#')) {
      final parts = initialLine.trim().split(RegExp(r'\s+'));
      if (parts.length >= 6) {
        sched = parts.sublist(0, 5).join(' ');
        cmd = parts.sublist(5).join(' ');
      }
    }
    final schedCtrl = TextEditingController(text: sched);
    final cmdCtrl = TextEditingController(text: cmd);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(editIndex == null ? 'Tambah Baris Cron' : 'Edit Baris Cron'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: schedCtrl,
              decoration: const InputDecoration(
                labelText: 'Waktu (Menit Jam Tgl Bulan Hari)',
                helperText: 'Contoh: */5 * * * * (tiap 5 menit) atau 0 4 * * * (jam 4 pagi)',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: cmdCtrl,
              decoration: const InputDecoration(
                labelText: 'Perintah / Script',
                helperText: 'Contoh: /etc/init.d/openclash restart',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          FilledButton(
            onPressed: () {
              final newLine = '${schedCtrl.text.trim()} ${cmdCtrl.text.trim()}';
              final lines = _cronCodeCtrl.text.split('\n');
              if (editIndex != null && editIndex >= 0 && editIndex < lines.length) {
                lines[editIndex] = newLine;
                _cronCodeCtrl.text = lines.join('\n');
              } else {
                final cur = _cronCodeCtrl.text.trimRight();
                _cronCodeCtrl.text = cur.isEmpty ? newLine : '$cur\n$newLine';
              }
              setState(() {});
              Navigator.pop(ctx);
            },
            child: const Text('Masukkan ke Editor (Lalu Klik SAVE)'),
          ),
        ],
      ),
    );
  }

  void _showCronLinesManagerDialog() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final lines = _cronCodeCtrl.text
              .split('\n')
              .where((l) => l.trim().isNotEmpty)
              .toList();

          return AlertDialog(
            title: const Text('Kelola Baris Cron'),
            content: SizedBox(
              width: double.maxFinite,
              child: lines.isEmpty
                  ? const Text('Belum ada baris jadwal di crontab.')
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: lines.length,
                      itemBuilder: (_, idx) {
                        final line = lines[idx];
                        return ListTile(
                          dense: true,
                          title: Text(line, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit, size: 18),
                                onPressed: () {
                                  Navigator.pop(ctx);
                                  _showCronHelperDialog(editIndex: idx, initialLine: line);
                                },
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                                onPressed: () {
                                  lines.removeAt(idx);
                                  _cronCodeCtrl.text = lines.join('\n');
                                  setDialogState(() {});
                                  setState(() {});
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tutup')),
            ],
          );
        },
      ),
    );
  }

  /// TAB REBOOT & SHUTDOWN
  Widget _buildPowerSection() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: const CircleAvatar(
              backgroundColor: Colors.orange,
              child: Icon(Icons.restart_alt, color: Colors.white),
            ),
            title: const Text('Reboot OpenWrt', style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: const Text('Mulai ulang sistem router OpenWrt (reboot).'),
            trailing: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.orange),
              onPressed: () => _confirmPowerAction(
                title: 'Konfirmasi Reboot',
                message: 'Yakin ingin memulai ulang (Reboot) perangkat OpenWrt sekarang?',
                command: 'reboot',
              ),
              child: const Text('REBOOT'),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const CircleAvatar(
              backgroundColor: Colors.redAccent,
              child: Icon(Icons.power_settings_new, color: Colors.white),
            ),
            title: const Text('Shutdown / Power Off', style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: const Text('Matikan daya perangkat OpenWrt sepenuhnya (poweroff).'),
            trailing: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => _confirmPowerAction(
                title: 'Konfirmasi Shutdown',
                message: 'Yakin ingin mematikan (Shutdown) perangkat OpenWrt sekarang?',
                command: 'poweroff',
              ),
              child: const Text('SHUTDOWN'),
            ),
          ),
        ),
      ],
    );
  }

  void _confirmPowerAction({
    required String title,
    required String message,
    required String command,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              Navigator.pop(ctx);
              await widget.ssh.runCommand(command);
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Perintah "$command" telah dikirim ke router.')),
              );
            },
            child: Text(command.toUpperCase()),
          ),
        ],
      ),
    );
  }
}
