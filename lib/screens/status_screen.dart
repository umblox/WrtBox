import 'dart:async';
import 'package:flutter/material.dart';
import '../services/ssh_service.dart';

class StatusScreen extends StatefulWidget {
  final SshService ssh;
  final String initialSection;

  const StatusScreen({
    super.key,
    required this.ssh,
    this.initialSection = 'status_overview',
  });

  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _loading = false;

  // Data Overview
  Map<String, dynamic> _boardInfo = {};
  Map<String, dynamic> _sysInfo = {};
  String _diskOverlay = '-';
  String _cpuTemp = '-';
  List<Map<String, String>> _dhcpLeases = [];

  // Data Logs, Processes, NetMon
  String _logsText = '';
  String _logFilter = '';
  String _processesText = '';
  List<Map<String, String>> _netDevStats = [];

  @override
  void initState() {
    super.initState();
    int startIdx = 0;
    if (widget.initialSection == 'status_logs') startIdx = 1;
    if (widget.initialSection == 'status_processes') startIdx = 2;
    if (widget.initialSection == 'status_netmon') startIdx = 3;

    _tabController = TabController(length: 4, vsync: this, initialIndex: startIdx);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) _refreshActiveTab();
    });
    _refreshActiveTab();
  }

  @override
  void didUpdateWidget(covariant StatusScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialSection != widget.initialSection) {
      int newIdx = 0;
      if (widget.initialSection == 'status_logs') newIdx = 1;
      if (widget.initialSection == 'status_processes') newIdx = 2;
      if (widget.initialSection == 'status_netmon') newIdx = 3;
      _tabController.animateTo(newIdx);
      _refreshActiveTab();
    }
  }

  Future<void> _refreshActiveTab() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      switch (_tabController.index) {
        case 0:
          await _loadOverview();
          break;
        case 1:
          await _loadLogs();
          break;
        case 2:
          await _loadProcesses();
          break;
        case 3:
          await _loadNetMonitor();
          break;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error memuat status: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadOverview() async {
    final board = await widget.ssh.ubusCall('system', 'board');
    final info = await widget.ssh.ubusCall('system', 'info');
    final disk = await widget.ssh.runCommand(
      "df -h /overlay 2>/dev/null | awk 'NR==2 {print \$3 \" / \" \$2 \" (\" \$5 \")\"}'",
    );
    final temp = await widget.ssh.runCommand(
      "cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo ''",
    );
    final leasesRaw = await widget.ssh.runCommand("cat /tmp/dhcp.leases 2>/dev/null");

    final leases = <Map<String, String>>[];
    for (final line in leasesRaw.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 4) {
        leases.add({
          'mac': parts[1],
          'ip': parts[2],
          'host': parts[3] == '*' ? 'Unknown' : parts[3],
        });
      }
    }

    String parsedTemp = '-';
    if (temp.isNotEmpty) {
      final val = int.tryParse(temp.trim());
      if (val != null) {
        parsedTemp = '${(val > 1000 ? val / 1000 : val).toStringAsFixed(1)} °C';
      }
    }

    setState(() {
      _boardInfo = board is Map<String, dynamic> ? board : {};
      _sysInfo = info is Map<String, dynamic> ? info : {};
      _diskOverlay = disk.isEmpty ? 'RootFS Standard' : disk;
      _cpuTemp = parsedTemp;
      _dhcpLeases = leases;
    });
  }

  Future<void> _releaseRam() async {
    setState(() => _loading = true);
    try {
      await widget.ssh.runCommand('sync && echo 3 > /proc/sys/vm/drop_caches');
      await _loadOverview();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('RAM Cache berhasil dibersihkan (Release RAM sukses)!'),
          backgroundColor: Colors.green,
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadLogs() async {
    final raw = await widget.ssh.runCommand('logread -l 200');
    setState(() => _logsText = raw);
  }

  Future<void> _loadProcesses() async {
    final raw = await widget.ssh.runCommand('top -b -n 1 | head -n 45');
    setState(() => _processesText = raw);
  }

  Future<void> _loadNetMonitor() async {
    final raw = await widget.ssh.runCommand('cat /proc/net/dev');
    final list = <Map<String, String>>[];
    final lines = raw.split('\n');
    for (var i = 2; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty || !line.contains(':')) continue;
      final splitColon = line.split(':');
      final iface = splitColon[0].trim();
      final cols = splitColon[1].trim().split(RegExp(r'\s+'));
      if (cols.length >= 9) {
        final rxBytes = int.tryParse(cols[0]) ?? 0;
        final rxPkts = cols[1];
        final txBytes = int.tryParse(cols[8]) ?? 0;
        final txPkts = cols[9];
        list.add({
          'iface': iface,
          'rx': '${_formatBytes(rxBytes)} ($rxPkts Pkts)',
          'tx': '${_formatBytes(txBytes)} ($txPkts Pkts)',
        });
      }
    }
    setState(() => _netDevStats = list);
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    double val = bytes.toDouble();
    while (val >= 1024 && i < suffixes.length - 1) {
      val /= 1024;
      i++;
    }
    return '${val.toStringAsFixed(2)}${suffixes[i]}';
  }

  String _formatUptime(int seconds) {
    final d = seconds ~/ 86400;
    final h = (seconds % 86400) ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    return '${d}d${h}h ${m}m${s}s';
  }

  @override
  void dispose() {
    _tabController.dispose();
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
                  controller: _tabController,
                  isScrollable: true,
                  tabs: const [
                    Tab(text: 'Overview'),
                    Tab(text: 'System Log'),
                    Tab(text: 'Processes'),
                    Tab(text: 'Traffic / NetMon'),
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
                onPressed: _refreshActiveTab,
              ),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildOverviewTab(),
              _buildLogsTab(),
              _buildProcessesTab(),
              _buildNetMonTab(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildOverviewTab() {
    final release = _boardInfo['release'] is Map ? _boardInfo['release'] : {};
    final mem = _sysInfo['memory'] is Map ? _sysInfo['memory'] : {};
    final totalMem = (mem['total'] ?? 1) as int;
    final availMem = (mem['available'] ?? mem['free'] ?? 0) as int;
    final usedMem = totalMem - availMem;
    final memRatio = (usedMem / totalMem).clamp(0.0, 1.0);
    final uptime = (_sysInfo['uptime'] ?? 0) as int;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.memory, color: Colors.lightBlueAccent),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Memory (RAM) & Release RAM',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _loading ? null : _releaseRam,
                      icon: const Icon(Icons.cleaning_services, size: 16),
                      label: const Text('Release RAM'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: memRatio,
                  minHeight: 10,
                  borderRadius: BorderRadius.circular(6),
                ),
                const SizedBox(height: 8),
                Text(
                  'Used: ${_formatBytes(usedMem)} / Total: ${_formatBytes(totalMem)} (Available:${_formatBytes(availMem)})',
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ],
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
                const Text(
                  'System Information (Auto-Detected)',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
                const Divider(),
                _infoRow('Hostname', '${_boardInfo['hostname'] ?? '-'}'),
                _infoRow('Model', '${_boardInfo['model'] ?? '-'}'),
                _infoRow('Architecture', '${_boardInfo['system'] ?? '-'}'),
                _infoRow('Firmware', '${release['description'] ?? '-'}'),
                _infoRow('Kernel Version', '${_boardInfo['kernel'] ?? '-'}'),
                _infoRow('Uptime', _formatUptime(uptime)),
                _infoRow('Temperature', _cpuTemp),
                _infoRow('Overlay Storage', _diskOverlay),
              ],
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
                Text(
                  'Active DHCP Leases (${_dhcpLeases.length} Perangkat)',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
                const Divider(),
                if (_dhcpLeases.isEmpty)
                  const Text('Tidak ada perangkat DHCP terdeteksi.')
                else
                  ..._dhcpLeases.map(
                    (e) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.devices, color: Colors.tealAccent),
                      title: Text('${e['host']} (${e['ip']})'),
                      subtitle: Text('MAC: ${e['mac']}'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label, style: const TextStyle(color: Colors.white60, fontSize: 13)),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogsTab() {
    final lines = _logsText
        .split('\n')
        .where((l) => _logFilter.isEmpty || l.toLowerCase().contains(_logFilter.toLowerCase()))
        .toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Cari kata kunci log (misal: dnsmasq, modem, cloudflared)...',
              prefixIcon: Icon(Icons.search),
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _logFilter = v),
          ),
        ),
        Expanded(
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.all(8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                lines.join('\n'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: Colors.greenAccent),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildProcessesTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Daftar Proses Berjalan (top)',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.cancel_outlined, color: Colors.redAccent, size: 18),
                label: const Text('Kill PID'),
                onPressed: () {
                  final pidCtrl = TextEditingController();
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Hentikan Proses (Kill PID)'),
                      content: TextField(
                        controller: pidCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Masukkan nomor PID'),
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
                        FilledButton(
                          onPressed: () async {
                            final pid = pidCtrl.text.trim();
                            if (pid.isNotEmpty) {
                              await widget.ssh.runCommand('kill -9 $pid');
                              if (ctx.mounted) Navigator.pop(ctx);
                              _loadProcesses();
                            }
                          },
                          child: const Text('Kill -9'),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.all(8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SingleChildScrollView(
                child: SelectableText(
                  _processesText,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNetMonTab() {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _netDevStats.length,
      itemBuilder: (ctx, i) {
        final item = _netDevStats[i];
        return Card(
          child: ListTile(
            leading: const Icon(Icons.swap_vert_circle, color: Colors.lightBlueAccent, size: 32),
            title: Text(
              item['iface'] ?? '-',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text('RX: ${item['rx']}\nTX:${item['tx']}'),
            isThreeLine: true,
          ),
        );
      },
    );
  }
}
