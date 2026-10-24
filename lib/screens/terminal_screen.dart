import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:dartssh2/dartssh2.dart';
import '../services/ssh_service.dart';

class _TerminalTabSession {
  final String title;
  final Terminal terminal;
  final TerminalController controller;
  SSHSession? sshSession;

  _TerminalTabSession({
    required this.title,
    required this.terminal,
    required this.controller,
    this.sshSession,
  });
}

class TerminalScreen extends StatefulWidget {
  final SshService ssh;

  const TerminalScreen({super.key, required this.ssh});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  final List<_TerminalTabSession> _sessions = [];
  int _activeIndex = 0;
  double _fontSize = 13.0;
  bool _ctrlActive = false;
  bool _altActive = false;

  List<Map<String, String>> _snippets = [
    {'title': 'Cek Status Interface (ubus)', 'cmd': 'ubus call network.interface dump\n'},
    {'title': 'Live System Log', 'cmd': 'logread -f\n'},
    {'title': 'Update daftar OPKG', 'cmd': 'opkg update\n'},
    {'title': 'Cek Proses & RAM (top)', 'cmd': 'top\n'},
    {'title': 'Restart Network', 'cmd': '/etc/init.d/network restart\n'},
    {'title': 'Restart OpenClash', 'cmd': '/etc/init.d/openclash restart\n'},
    {'title': 'Cek Status Cloudflared', 'cmd': '/etc/init.d/cloudflared status\n'},
  ];

  @override
  void initState() {
    super.initState();
    _loadSnippets();
    _createNewSession();
  }

  Future<void> _loadSnippets() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('terminal_snippets');
    if (saved != null && saved.isNotEmpty) {
      setState(() {
        _snippets = saved.map((s) => Map<String, String>.from(json.decode(s))).toList();
      });
    }
  }

  Future<void> _saveSnippets() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'terminal_snippets',
      _snippets.map((e) => json.encode(e)).toList(),
    );
  }

  Future<void> _createNewSession() async {
    final term = Terminal(maxLines: 10000);
    final ctrl = TerminalController();
    final tabTitle = 'SSH #${_sessions.length + 1}';

    final tabSession = _TerminalTabSession(
      title: tabTitle,
      terminal: term,
      controller: ctrl,
    );

    setState(() {
      _sessions.add(tabSession);
      _activeIndex = _sessions.length - 1;
    });

    term.write('Connecting to OpenWrt PTY Shell ($tabTitle)...\r\n');

    try {
      final shell = await widget.ssh.createShell(width: term.viewWidth, height: term.viewHeight);
      tabSession.sshSession = shell;

      term.onOutput = (String data) {
        String out = data;
        if (_ctrlActive && out.isNotEmpty) {
          final code = out.toUpperCase().codeUnitAt(0);
          if (code >= 64 && code <= 95) {
            out = String.fromCharCode(code - 64);
          }
          setState(() => _ctrlActive = false);
        } else if (_altActive && out.isNotEmpty) {
          out = '\x1b$out';
          setState(() => _altActive = false);
        }
        shell.write(Uint8List.fromList(utf8.encode(out)));
      };

      term.onResize = (int w, int h, int pw, int ph) {
        shell.resizeTerminal(w, h, pw, ph);
      };

      shell.stdout.listen((data) {
        term.write(utf8.decode(data, allowMalformed: true));
      });

      shell.stderr.listen((data) {
        term.write(utf8.decode(data, allowMalformed: true));
      });

      shell.done.then((_) {
        term.write('\r\n[Session Closed]\r\n');
      });
    } catch (e) {
      term.write('\r\n[Error membuka sesi shell: $e]\r\n');
    }
  }

  void _sendRawToActive(String seq) {
    if (_sessions.isEmpty) return;
    final session = _sessions[_activeIndex].sshSession;
    if (session != null) {
      session.write(Uint8List.fromList(utf8.encode(seq)));
    }
  }

  void _showSnippetsSheet() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.bolt, color: Colors.amberAccent),
                title: const Text('JuiceSSH Snippets (Perintah Cepat)', style: TextStyle(fontWeight: FontWeight.bold)),
                trailing: FilledButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Tambah'),
                  onPressed: () {
                    final titleCtrl = TextEditingController();
                    final cmdCtrl = TextEditingController();
                    showDialog(
                      context: context,
                      builder: (dCtx) => AlertDialog(
                        title: const Text('Tambah Snippet Perintah'),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: 'Nama Snippet')),
                            const SizedBox(height: 8),
                            TextField(controller: cmdCtrl, decoration: const InputDecoration(labelText: 'Perintah Shell')),
                          ],
                        ),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(dCtx), child: const Text('Batal')),
                          FilledButton(
                            onPressed: () {
                              if (cmdCtrl.text.trim().isNotEmpty) {
                                setState(() {
                                  _snippets.add({
                                    'title': titleCtrl.text.trim().isEmpty ? cmdCtrl.text.trim() : titleCtrl.text.trim(),
                                    'cmd': '${cmdCtrl.text.trim()}\n',
                                  });
                                });
                                _saveSnippets();
                                setSheetState(() {});
                              }
                              Navigator.pop(dCtx);
                            },
                            child: const Text('Simpan'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: _snippets.length,
                  itemBuilder: (_, idx) {
                    final snip = _snippets[idx];
                    return ListTile(
                      dense: true,
                      title: Text(snip['title'] ?? '', style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text((snip['cmd'] ?? '').trim(), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                        onPressed: () {
                          setState(() => _snippets.removeAt(idx));
                          _saveSnippets();
                          setSheetState(() {});
                        },
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        _sendRawToActive(snip['cmd'] ?? '');
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    for (final s in _sessions) {
      s.sshSession?.close();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activeSession = _sessions.isNotEmpty ? _sessions[_activeIndex] : null;

    return Column(
      children: [
        // Baris Multi-Session Tab + Kontrol Zoom Font, Paste, & Snippets
        Container(
          color: const Color(0xFF1B222D),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _sessions.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 4),
                    itemBuilder: (ctx, i) {
                      final selected = i == _activeIndex;
                      return ChoiceChip(
                        visualDensity: VisualDensity.compact,
                        selected: selected,
                        label: Text(_sessions[i].title, style: const TextStyle(fontSize: 11)),
                        onSelected: (_) => setState(() => _activeIndex = i),
                      );
                    },
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_box_outlined, size: 20),
                tooltip: 'Tab Terminal Baru',
                onPressed: _createNewSession,
              ),
              IconButton(
                icon: const Icon(Icons.bolt, size: 20, color: Colors.amberAccent),
                tooltip: 'Snippets (Perintah Tersimpan)',
                onPressed: _showSnippetsSheet,
              ),
              IconButton(
                icon: const Icon(Icons.content_paste, size: 18),
                tooltip: 'Paste dari Clipboard',
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data?.text != null && data!.text!.isNotEmpty) {
                    _sendRawToActive(data.text!);
                  }
                },
              ),
              IconButton(
                icon: const Icon(Icons.text_decrease, size: 18),
                tooltip: 'Perkecil Font',
                onPressed: () => setState(() => _fontSize = (_fontSize - 1).clamp(9.0, 24.0)),
              ),
              IconButton(
                icon: const Icon(Icons.text_increase, size: 18),
                tooltip: 'Perbesar Font',
                onPressed: () => setState(() => _fontSize = (_fontSize + 1).clamp(9.0, 24.0)),
              ),
            ],
          ),
        ),
        // Layar Utama Terminal Xterm
        Expanded(
          child: activeSession == null
              ? const Center(child: CircularProgressIndicator())
              : TerminalView(
                  activeSession.terminal,
                  controller: activeSession.controller,
                  autofocus: true,
                  backgroundOpacity: 1.0,
                  textStyle: TerminalStyle(
                    fontSize: _fontSize,
                    fontFamily: 'monospace',
                  ),
                ),
        ),
        // JuiceSSH Extra Keys Bar (2 Baris Tombol Khusus di Atas Keyboard)
        Container(
          color: const Color(0xFF161B22),
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _extraKeyBtn('ESC', () => _sendRawToActive('\x1b')),
                    _extraKeyBtn('TAB', () => _sendRawToActive('\t')),
                    _extraKeyBtn(
                      'CTRL',
                      () => setState(() => _ctrlActive = !_ctrlActive),
                      active: _ctrlActive,
                    ),
                    _extraKeyBtn(
                      'ALT',
                      () => setState(() => _altActive = !_altActive),
                      active: _altActive,
                    ),
                    _extraKeyBtn('↑', () => _sendRawToActive('\x1b[A')),
                    _extraKeyBtn('↓', () => _sendRawToActive('\x1b[B')),
                    _extraKeyBtn('←', () => _sendRawToActive('\x1b[D')),
                    _extraKeyBtn('→', () => _sendRawToActive('\x1b[C')),
                    _extraKeyBtn('Ctrl+C', () => _sendRawToActive('\x03'), color: Colors.redAccent),
                    _extraKeyBtn('Ctrl+L', () => _sendRawToActive('\x0c')),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _extraKeyBtn('/', () => _sendRawToActive('/')),
                    _extraKeyBtn('-', () => _sendRawToActive('-')),
                    _extraKeyBtn('|', () => _sendRawToActive('|')),
                    _extraKeyBtn('~', () => _sendRawToActive('~')),
                    _extraKeyBtn('_', () => _sendRawToActive('_')),
                    _extraKeyBtn('*', () => _sendRawToActive('*')),
                    _extraKeyBtn('&', () => _sendRawToActive('&')),
                    _extraKeyBtn('HOME', () => _sendRawToActive('\x1b[H')),
                    _extraKeyBtn('END', () => _sendRawToActive('\x1b[F')),
                    _extraKeyBtn('PGUP', () => _sendRawToActive('\x1b[5~')),
                    _extraKeyBtn('PGDN', () => _sendRawToActive('\x1b[6~')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _extraKeyBtn(String label, VoidCallback onTap, {bool active = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2.5),
      child: SizedBox(
        height: 30,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            backgroundColor: active ? const Color(0xFF0088CC) : const Color(0xFF21262D),
            foregroundColor: color ?? Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            side: BorderSide(color: active ? Colors.lightBlueAccent : Colors.white24),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
          onPressed: onTap,
          child: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
        ),
      ),
    );
  }
}
