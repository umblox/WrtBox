import 'package:flutter/material.dart';
import '../services/ssh_service.dart';

class NetworkScreen extends StatefulWidget {
  final SshService ssh;
  final int initialTab;

  const NetworkScreen({
    super.key,
    required this.ssh,
    this.initialTab = 0,
  });

  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<NetworkScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _refreshing = false;

  // Data Dinamis Hasil Deteksi OpenWrt
  List<Map<String, dynamic>> _interfaces = [];
  List<Map<String, dynamic>> _devices = [];

  // Global Network Options
  final TextEditingController _ulaPrefixCtrl = TextEditingController();
  bool _tcpL3mdev = false;
  bool _udpL3mdev = false;
  String _packetSteering = '0';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this, initialIndex: widget.initialTab);
    _loadAllNetworkData();
  }

  @override
  void didUpdateWidget(covariant NetworkScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTab != widget.initialTab) {
      _tabController.animateTo(widget.initialTab);
    }
  }

  Future<void> _loadAllNetworkData() async {
    if (!mounted) return;
    setState(() => _refreshing = true);
    try {
      await Future.wait([
        _detectInterfaces(),
        _detectDevices(),
        _detectGlobalOptions(),
      ]);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal mendeteksi konfigurasi Network: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  /// 1. Deteksi Dinamis Semua Interfaces dari ubus & uci
  Future<void> _detectInterfaces() async {
    final dump = await widget.ssh.ubusCall('network.interface', 'dump');
    final devStatus = await widget.ssh.ubusCall('network.device', 'status');
    final uciNetRaw = await widget.ssh.runCommand('uci show network 2>/dev/null');

    // Parse semua interface yang terdaftar di /etc/config/network (termasuk yang sedang down/unmanaged)
    final Map<String, Map<String, String>> uciIfaces = {};
    for (final line in uciNetRaw.split('\n')) {
      final match = RegExp(r'^network\.([^.=]+)=interface$').firstMatch(line.trim());
      if (match != null) {
        final name = match.group(1)!;
        if (name != 'loopback') {
          uciIfaces[name] = {'name': name};
        }
      }
    }
    for (final line in uciNetRaw.split('\n')) {
      final optMatch = RegExp(r"^network\.([^.=]+)\.([^=]+)='?([^']*)'?$").firstMatch(line.trim());
      if (optMatch != null) {
        final sec = optMatch.group(1)!;
        final key = optMatch.group(2)!;
        final val = optMatch.group(3)!;
        if (uciIfaces.containsKey(sec)) {
          uciIfaces[sec]![key] = val;
        }
      }
    }

    final List<dynamic> ubusList = (dump is Map && dump['interface'] is List) ? dump['interface'] : [];
    final Map<String, dynamic> devMap = (devStatus is Map<String, dynamic>) ? devStatus : {};

    final List<Map<String, dynamic>> parsed = [];

    for (final entry in uciIfaces.entries) {
      final ifaceName = entry.key;
      final uciData = entry.value;

      Map<String, dynamic> ubusItem = {};
      for (final item in ubusList) {
        if (item is Map<String, dynamic> && item['interface'] == ifaceName) {
          ubusItem = item;
          break;
        }
      }

      final devName = (ubusItem['l3_device'] ?? ubusItem['device'] ?? uciData['device'] ?? uciData['ifname'] ?? '-')
          .toString();
      final protoRaw = (ubusItem['proto'] ?? uciData['proto'] ?? 'none').toString();
      final isUp = ubusItem['up'] == true;
      final uptime = (ubusItem['uptime'] ?? 0) as int;

      // Ambil IPv4
      String ipv4 = '';
      if (ubusItem['ipv4-address'] is List && (ubusItem['ipv4-address'] as List).isNotEmpty) {
        final firstIp = (ubusItem['ipv4-address'] as List).first;
        if (firstIp is Map) {
          ipv4 = '${firstIp['address']}/${firstIp['mask']}';
        }
      } else if (uciData['ipaddr'] != null) {
        ipv4 = uciData['ipaddr']!;
      }

      // Ambil Statistik RX/TX & MAC dari ubus network.device status
      String mac = '';
      int rxBytes = 0;
      int rxPkts = 0;
      int txBytes = 0;
      int txPkts = 0;
      bool devPresent = false;

      if (devMap.containsKey(devName) && devMap[devName] is Map) {
        final d = devMap[devName] as Map;
        devPresent = d['present'] == true || d['up'] == true;
        mac = (d['macaddr'] ?? '').toString().toUpperCase();
        if (d['statistics'] is Map) {
          final st = d['statistics'] as Map;
          rxBytes = (st['rx_bytes'] ?? 0) as int;
          rxPkts = (st['rx_packets'] ?? 0) as int;
          txBytes = (st['tx_bytes'] ?? 0) as int;
          txPkts = (st['tx_packets'] ?? 0) as int;
        }
      }

      parsed.add({
        'name': ifaceName,
        'device': devName,
        'proto': _prettyProto(protoRaw),
        'raw_proto': protoRaw,
        'up': isUp,
        'present': devPresent,
        'uptime': uptime,
        'mac': mac,
        'rx_bytes': rxBytes,
        'rx_pkts': rxPkts,
        'tx_bytes': txBytes,
        'tx_pkts': txPkts,
        'ipv4': ipv4,
      });
    }

    setState(() => _interfaces = parsed);
  }

  String _prettyProto(String proto) {
    switch (proto) {
      case 'static':
        return 'Static address';
      case 'dhcp':
        return 'DHCP client';
      case 'none':
        return 'Unmanaged';
      case 'pppoe':
        return 'PPPoE';
      case 'modemmanager':
        return 'ModemManager';
      default:
        return proto;
    }
  }

  /// 2. Deteksi Dinamis Semua Devices dari ubus network.device status
  Future<void> _detectDevices() async {
    final devStatus = await widget.ssh.ubusCall('network.device', 'status');
    final Map<String, dynamic> devMap = (devStatus is Map<String, dynamic>) ? devStatus : {};
    final List<Map<String, dynamic>> list = [];

    devMap.forEach((devName, value) {
      if (devName == 'lo' || value is! Map) return;
      final typeRaw = (value['type'] ?? 'Network device').toString();
      final isBridge = typeRaw.toLowerCase().contains('bridge') || devName.startsWith('br-');
      final mac = (value['macaddr'] ?? '00:00:00:00:00:00').toString().toUpperCase();
      final mtu = (value['mtu'] ?? 1500).toString();

      list.add({
        'name': devName,
        'type': isBridge ? 'Bridge device' : 'Network device',
        'mac': mac,
        'mtu': mtu,
      });
    });

    list.sort((a, b) => a['name'].toString().compareTo(b['name'].toString()));
    setState(() => _devices = list);
  }

  /// 3. Deteksi Global Network Options dari /etc/config/network (globals)
  Future<void> _detectGlobalOptions() async {
    final ula = await widget.ssh.runCommand('uci -q get network.globals.ula_prefix');
    final tcpL3 = await widget.ssh.runCommand('uci -q get network.globals.tcp_l3mdev');
    final udpL3 = await widget.ssh.runCommand('uci -q get network.globals.udp_l3mdev');
    final steering = await widget.ssh.runCommand('uci -q get network.globals.packet_steering');

    setState(() {
      _ulaPrefixCtrl.text = ula;
      _tcpL3mdev = tcpL3 == '1';
      _udpL3mdev = udpL3 == '1';
      _packetSteering = steering.isEmpty ? '0' : steering;
    });
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
    return '${val.toStringAsFixed(2)} ${suffixes[i]}';
  }

  String _formatUptime(int seconds) {
    if (seconds <= 0) return '';
    final d = seconds ~/ 86400;
    final h = (seconds % 86400) ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    return '${d > 0 ? '${d}d ' : ''}${h}h ${m}m ${s}s';
  }

  Future<void> _saveGlobalOptionsToUci() async {
    await widget.ssh.runCommand("uci set network.globals=globals");
    if (_ulaPrefixCtrl.text.trim().isEmpty) {
      await widget.ssh.runCommand("uci -q delete network.globals.ula_prefix");
    } else {
      await widget.ssh.runCommand("uci set network.globals.ula_prefix='${_ulaPrefixCtrl.text.trim()}'");
    }
    await widget.ssh.runCommand("uci set network.globals.tcp_l3mdev='${_tcpL3mdev ? '1' : '0'}'");
    await widget.ssh.runCommand("uci set network.globals.udp_l3mdev='${_udpL3mdev ? '1' : '0'}'");
    await widget.ssh.runCommand("uci set network.globals.packet_steering='$_packetSteering'");
  }

  Future<void> _handleSaveAndApply() async {
    setState(() => _refreshing = true);
    try {
      if (_tabController.index == 2) {
        await _saveGlobalOptionsToUci();
      }
      await widget.ssh.runCommand('uci commit network && /etc/init.d/network reload');
      await _loadAllNetworkData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Konfigurasi Network berhasil disimpan & diterapkan (Save & Apply)!'),
          backgroundColor: Colors.green,
        ),
      );
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _handleSaveOnly() async {
    setState(() => _refreshing = true);
    try {
      if (_tabController.index == 2) {
        await _saveGlobalOptionsToUci();
      }
      await widget.ssh.runCommand('uci commit network');
      await _loadAllNetworkData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Perubahan disimpan (UCI Commit).')),
      );
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _handleReset() async {
    setState(() => _refreshing = true);
    try {
      await widget.ssh.runCommand('uci revert network');
      await _loadAllNetworkData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Perubahan dibatalkan (Reset).')),
      );
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _ulaPrefixCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Baris Tab: Interfaces | Devices | Global network options + Indikator REFRESHING
        Container(
          color: const Color(0xFF1B222D),
          padding: const EdgeInsets.only(right: 8),
          child: Row(
            children: [
              Expanded(
                child: TabBar(
                  controller: _tabController,
                  isScrollable: true,
                  tabs: const [
                    Tab(text: 'Interfaces'),
                    Tab(text: 'Devices'),
                    Tab(text: 'Global network options'),
                  ],
                ),
              ),
              InkWell(
                onTap: _loadAllNetworkData,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _refreshing ? const Color(0xFF0077B5) : Colors.white12,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _refreshing ? 'REFRESHING' : 'REFRESH',
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildInterfacesTab(),
              _buildDevicesTab(),
              _buildGlobalOptionsTab(),
            ],
          ),
        ),
        // Bottom Sticky Bar: SAVE & APPLY | SAVE | RESET
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: const BoxDecoration(
            color: Color(0xFF1B222D),
            border: Border(top: BorderSide(color: Colors.white12)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2B7BB9)),
                onPressed: _refreshing ? null : _handleSaveAndApply,
                child: const Text('SAVE & APPLY', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2B7BB9)),
                onPressed: _refreshing ? null : _handleSaveOnly,
                child: const Text('SAVE', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFFA61C1C)),
                onPressed: _refreshing ? null : _handleReset,
                child: const Text('RESET', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// TAB 1: INTERFACES (100% Dinamis)
  Widget _buildInterfacesTab() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        ..._interfaces.map((iface) {
          final name = iface['name'].toString();
          final isWanLike = name.contains('wan') || name.contains('tether') || name.contains('modem');
          final badgeColor = isWanLike ? const Color(0xFFE88B8B) : const Color(0xFF8BE896);
          final present = iface['present'] == true;
          final uptimeStr = _formatUptime(iface['uptime'] as int);

          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Kotak Visual Interface (Kiri)
                      Container(
                        width: 110,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white24),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          children: [
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              decoration: BoxDecoration(
                                color: badgeColor,
                                borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
                              ),
                              child: Text(
                                name,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.black87,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 8),
                              child: Icon(Icons.settings_ethernet, size: 28, color: Colors.white70),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                '(${iface['device']})',
                                style: const TextStyle(fontSize: 11, color: Colors.white60),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 14),
                      // Detail Status Interface (Kanan)
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _kvText('Protocol:', iface['proto'].toString()),
                            if (uptimeStr.isNotEmpty) _kvText('Uptime:', uptimeStr),
                            if (iface['mac'].toString().isNotEmpty) _kvText('MAC:', iface['mac'].toString()),
                            _kvText(
                              'RX:',
                              '${_formatBytes(iface['rx_bytes'] as int)} (${iface['rx_pkts']} Pkts.)',
                            ),
                            _kvText(
                              'TX:',
                              '${_formatBytes(iface['tx_bytes'] as int)} (${iface['tx_pkts']} Pkts.)',
                            ),
                            if (iface['ipv4'].toString().isNotEmpty) _kvText('IPv4:', iface['ipv4'].toString()),
                            if (!present && iface['raw_proto'] != 'none')
                              const Padding(
                                padding: EdgeInsets.only(top: 4),
                                child: Text(
                                  'Error: Network device is not present',
                                  style: TextStyle(
                                    color: Colors.redAccent,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 20),
                  // Baris Tombol: RESTART | STOP | EDIT | DELETE
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    alignment: WrapAlignment.center,
                    children: [
                      _smallActionBtn('RESTART', Colors.white24, () async {
                        await widget.ssh.runCommand('ifup $name');
                        _loadAllNetworkData();
                      }),
                      _smallActionBtn('STOP', Colors.white12, () async {
                        await widget.ssh.runCommand('ifdown $name');
                        _loadAllNetworkData();
                      }),
                      _smallActionBtn('EDIT', const Color(0xFF2B7BB9), () {
                        _showInterfaceDialog(existing: iface);
                      }),
                      _smallActionBtn('DELETE', const Color(0xFFA61C1C), () async {
                        await widget.ssh.runCommand('uci delete network.$name');
                        _loadAllNetworkData();
                      }),
                    ],
                  ),
                ],
              ),
            ),
          );
        }),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2B7BB9)),
            onPressed: () => _showInterfaceDialog(),
            child: const Text('ADD NEW INTERFACE...'),
          ),
        ),
      ],
    );
  }

  Widget _kvText(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(fontSize: 12, color: Colors.white),
          children: [
            TextSpan(text: '$k ', style: const TextStyle(fontWeight: FontWeight.bold)),
            TextSpan(text: v, style: const TextStyle(color: Colors.white70)),
          ],
        ),
      ),
    );
  }

  Widget _smallActionBtn(String label, Color bg, VoidCallback onTap) {
    return SizedBox(
      height: 30,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        onPressed: onTap,
        child: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
      ),
    );
  }

  void _showInterfaceDialog({Map<String, dynamic>? existing}) {
    final nameCtrl = TextEditingController(text: existing?['name']?.toString() ?? '');
    final devCtrl = TextEditingController(text: existing?['device']?.toString() ?? 'eth0');
    final ipCtrl = TextEditingController(
      text: existing?['ipv4']?.toString().split('/').first ?? '',
    );
    String proto = existing?['raw_proto']?.toString() ?? 'dhcp';
    if (!['static', 'dhcp', 'none', 'pppoe'].contains(proto)) proto = 'dhcp';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'Add New Interface' : 'Edit Interface: ${existing['name']}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (existing == null)
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: 'Nama Interface (contoh: wan2 / modem)'),
                  ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: proto,
                  decoration: const InputDecoration(labelText: 'Protocol'),
                  items: const [
                    DropdownMenuItem(value: 'dhcp', child: Text('DHCP client')),
                    DropdownMenuItem(value: 'static', child: Text('Static address')),
                    DropdownMenuItem(value: 'none', child: Text('Unmanaged')),
                    DropdownMenuItem(value: 'pppoe', child: Text('PPPoE')),
                  ],
                  onChanged: (v) {
                    if (v != null) setDialogState(() => proto = v);
                  },
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: devCtrl,
                  decoration: const InputDecoration(labelText: 'Device (contoh: eth1, usb0, wwan0, br-lan)'),
                ),
                if (proto == 'static') ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: ipCtrl,
                    decoration: const InputDecoration(labelText: 'IPv4 Address (contoh: 192.168.1.1)'),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
            FilledButton(
              onPressed: () async {
                final ifName = nameCtrl.text.trim();
                if (ifName.isEmpty) return;
                await widget.ssh.runCommand("uci set network.$ifName=interface");
                await widget.ssh.runCommand("uci set network.$ifName.proto='$proto'");
                await widget.ssh.runCommand("uci set network.$ifName.device='${devCtrl.text.trim()}'");
                if (proto == 'static' && ipCtrl.text.trim().isNotEmpty) {
                  await widget.ssh.runCommand("uci set network.$ifName.ipaddr='${ipCtrl.text.trim()}'");
                  await widget.ssh.runCommand("uci set network.$ifName.netmask='255.255.255.0'");
                }
                if (ctx.mounted) Navigator.pop(ctx);
                _loadAllNetworkData();
              },
              child: const Text('Simpan ke UCI'),
            ),
          ],
        ),
      ),
    );
  }

  /// TAB 2: DEVICES (100% Dinamis + Edit MTU)
  Widget _buildDevicesTab() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        ..._devices.map((dev) {
          final devName = dev['name'].toString();
          return Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Device:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            Chip(
                              avatar: const Icon(Icons.cable, size: 16),
                              label: Text(devName, style: const TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Type:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            Text(dev['type'].toString(), style: const TextStyle(fontSize: 13)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('MAC Address:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                            Text(dev['mac'].toString(), style: const TextStyle(fontSize: 12, color: Colors.white70)),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('MTU:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                            Text(dev['mtu'].toString(), style: const TextStyle(fontSize: 12, color: Colors.white70)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _smallActionBtn('CONFIGURE...', const Color(0xFF2B7BB9), () {
                        _showConfigureDeviceDialog(devName, dev['mtu'].toString());
                      }),
                      const SizedBox(width: 10),
                      _smallActionBtn('UNCONFIGURE', const Color(0xFFA61C1C), () async {
                        await widget.ssh.runCommand("ip link set dev $devName mtu 1500");
                        _loadAllNetworkData();
                      }),
                    ],
                  ),
                ],
              ),
            ),
          );
        }),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2B7BB9)),
            onPressed: () => _showConfigureDeviceDialog('', '1500'),
            child: const Text('ADD DEVICE CONFIGURATION...'),
          ),
        ),
      ],
    );
  }

  void _showConfigureDeviceDialog(String devName, String currentMtu) {
    final nameCtrl = TextEditingController(text: devName);
    final mtuCtrl = TextEditingController(text: currentMtu);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(devName.isEmpty ? 'Add Device Configuration' : 'Configure Device: $devName'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              readOnly: devName.isNotEmpty,
              decoration: const InputDecoration(labelText: 'Device Name (contoh: br-lan, eth1, tap0)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: mtuCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'MTU (contoh: 1450 atau 1500)'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          FilledButton(
            onPressed: () async {
              final d = nameCtrl.text.trim();
              final mtu = int.tryParse(mtuCtrl.text.trim()) ?? 1500;
              if (d.isNotEmpty) {
                await widget.ssh.runCommand("ip link set dev '$d' mtu $mtu");
              }
              if (ctx.mounted) Navigator.pop(ctx);
              _loadAllNetworkData();
            },
            child: const Text('Terapkan'),
          ),
        ],
      ),
    );
  }

  /// TAB 3: GLOBAL NETWORK OPTIONS
  Widget _buildGlobalOptionsTab() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Global network options',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _ulaPrefixCtrl,
                  decoration: const InputDecoration(
                    labelText: 'IPv6 ULA-Prefix',
                    helperText: 'Unique Local Address (RFC4193) - prefix (fd00::/8).',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('TCP Layer 3 Master Device (tcp_l3mdev) accept'),
                  subtitle: const Text(
                    'TCP services running on this device in the default VRF context shall work across all VRF domains.',
                    style: TextStyle(fontSize: 11.5),
                  ),
                  value: _tcpL3mdev,
                  onChanged: (v) => setState(() => _tcpL3mdev = v ?? false),
                ),
                const Divider(),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('UDP Layer 3 Master Device (udp_l3mdev) accept'),
                  subtitle: const Text(
                    'UDP services running on this device in the default VRF context shall work across all VRF domains.',
                    style: TextStyle(fontSize: 11.5),
                  ),
                  value: _udpL3mdev,
                  onChanged: (v) => setState(() => _udpL3mdev = v ?? false),
                ),
                const Divider(),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: ['0', '1', '2'].contains(_packetSteering) ? _packetSteering : '0',
                  decoration: const InputDecoration(
                    labelText: 'Packet Steering',
                    helperText: 'Enable packet steering across CPUs. May help or hinder network speed.',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: '0', child: Text('Disabled')),
                    DropdownMenuItem(value: '1', child: Text('Enabled')),
                    DropdownMenuItem(value: '2', child: Text('Enabled (all CPUs)')),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _packetSteering = v);
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
