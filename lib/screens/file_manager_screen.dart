import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:dartssh2/dartssh2.dart';
import '../services/ssh_service.dart';

class RemoteFileEntry {
  final String name;
  final String fullPath;
  final bool isDirectory;
  final bool isSymlink;
  final int size;
  final String permissions;
  final String octalPerm;
  final String owner;
  final String modified;

  RemoteFileEntry({
    required this.name,
    required this.fullPath,
    required this.isDirectory,
    required this.isSymlink,
    required this.size,
    required this.permissions,
    required this.octalPerm,
    required this.owner,
    required this.modified,
  });
}

class FileManagerScreen extends StatefulWidget {
  final SshService ssh;

  const FileManagerScreen({super.key, required this.ssh});

  @override
  State<FileManagerScreen> createState() => _FileManagerScreenState();
}

class _FileManagerScreenState extends State<FileManagerScreen> {
  String _currentPath = '/';
  bool _loading = false;
  String _searchQuery = '';
  String _sortBy = 'name'; // 'name', 'size', 'modified'
  bool _sortAsc = true;
  List<RemoteFileEntry> _entries = [];
  String? _clipboardPath;
  bool _clipboardIsCut = false;

  final List<Map<String, String>> _quickBookmarks = const [
    {'label': 'Root (/)', 'path': '/'},
    {'label': 'UCI Config', 'path': '/etc/config'},
    {'label': 'Init.d', 'path': '/etc/init.d'},
    {'label': 'Home (/root)', 'path': '/root'},
    {'label': 'OpenClash', 'path': '/etc/openclash'},
    {'label': 'Nikki', 'path': '/etc/nikki'},
    {'label': 'LuCI Share', 'path': '/usr/share/luci/menu.d'},
    {'label': 'Temp (/tmp)', 'path': '/tmp'},
    {'label': 'Mount (/mnt)', 'path': '/mnt'},
  ];

  @override
  void initState() {
    super.initState();
    _loadDirectory('/');
  }

  Future<void> _loadDirectory(String targetPath) async {
    if (!mounted) return;
    setState(() => _loading = true);

    try {
      String cleanPath = targetPath.trim();
      if (cleanPath.isEmpty) cleanPath = '/';
      if (cleanPath.length > 1 && cleanPath.endsWith('/')) {
        cleanPath = cleanPath.substring(0, cleanPath.length - 1);
      }

      // Gunakan ls -la + stat via BusyBox untuk akurasi permission, ukuran, dan tanggal modifikasi di semua arsitektur OpenWrt
      final cmd = '''
cd '$cleanPath' 2>/dev/null && pwd && ls -la --full-time 2>/dev/null || (cd '$cleanPath' && pwd && ls -la)
''';
      final raw = await widget.ssh.runCommand(cmd);
      final lines = raw.split('\n');
      if (lines.isEmpty) throw Exception('Direktori tidak dapat diakses.');

      final resolvedPath = lines.first.trim().isNotEmpty ? lines.first.trim() : cleanPath;
      final List<RemoteFileEntry> parsed = [];

      for (int i = 1; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.isEmpty || line.startsWith('total ')) continue;

        final parts = line.split(RegExp(r'\s+'));
        if (parts.length < 8) continue;

        final permStr = parts[0];
        final owner = '${parts[2]}:${parts[3]}';
        final sizeVal = int.tryParse(parts[4]) ?? 0;

        String modDate = '';
        String fileName = '';

        // Deteksi format ls --full-time vs ls standar BusyBox
        if (parts.length >= 9 && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(parts[5])) {
          final timeShort = parts[6].split('.').first;
          modDate = '${parts[5]} $timeShort';
          fileName = parts.sublist(8).join(' ');
        } else {
          modDate = '${parts[5]} ${parts[6]} ${parts[7]}';
          fileName = parts.sublist(8).join(' ');
        }

        if (fileName == '.' || fileName == '..' || fileName.isEmpty) continue;

        final isLink = permStr.startsWith('l');
        String displayName = fileName;
        if (isLink && fileName.contains(' -> ')) {
          displayName = fileName.split(' -> ').first;
        }

        final isDir = permStr.startsWith('d') || (isLink && !displayName.contains('.'));
        final fullItemPath = resolvedPath == '/' ? '/$displayName' : '$resolvedPath/$displayName';

        parsed.add(
          RemoteFileEntry(
            name: displayName,
            fullPath: fullItemPath,
            isDirectory: isDir,
            isSymlink: isLink,
            size: sizeVal,
            permissions: permStr,
            octalPerm: _permStringToOctal(permStr),
            owner: owner,
            modified: modDate,
          ),
        );
      }

      _sortEntries(parsed);

      setState(() {
        _currentPath = resolvedPath;
        _entries = parsed;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal membuka direktori $targetPath: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _sortEntries(List<RemoteFileEntry> list) {
    list.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      int cmp = 0;
      switch (_sortBy) {
        case 'size':
          cmp = a.size.compareTo(b.size);
          break;
        case 'modified':
          cmp = a.modified.compareTo(b.modified);
          break;
        default:
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
      return _sortAsc ? cmp : -cmp;
    });
  }

  String _permStringToOctal(String perm) {
    if (perm.length < 10) return '0644';
    int special = 0;
    int u = 0, g = 0, o = 0;

    if (perm[1] == 'r') u += 4;
    if (perm[2] == 'w') u += 2;
    if (perm[3] == 'x' || perm[3] == 's') u += 1;
    if (perm[3] == 's' || perm[3] == 'S') special += 4;

    if (perm[4] == 'r') g += 4;
    if (perm[5] == 'w') g += 2;
    if (perm[6] == 'x' || perm[6] == 's') g += 1;
    if (perm[6] == 's' || perm[6] == 'S') special += 2;

    if (perm[7] == 'r') o += 4;
    if (perm[8] == 'w') o += 2;
    if (perm[9] == 'x' || perm[9] == 't') o += 1;
    if (perm[9] == 't' || perm[9] == 'T') special += 1;

    return '$special$u$g$o';
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    int idx = 0;
    double val = bytes.toDouble();
    while (val >= 1024 && idx < units.length - 1) {
      val /= 1024;
      idx++;
    }
    return '${val.toStringAsFixed(idx == 0 ? 0 : 1)} ${units[idx]}';
  }

  void _navigateUp() {
    if (_currentPath == '/') return;
    final parts = _currentPath.split('/')..removeLast();
    final parent = parts.join('/');
    _loadDirectory(parent.isEmpty ? '/' : parent);
  }

  /// Dialog Lompat ke Direktori Mana Saja
  void _showJumpPathDialog() {
    final ctrl = TextEditingController(text: _currentPath);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Buka Jalur Direktori'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Path Direktori',
            helperText: 'Contoh: /etc/config, /usr/bin, /mnt/sda1',
            prefixIcon: Icon(Icons.folder_open),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _loadDirectory(ctrl.text.trim());
            },
            child: const Text('Buka'),
          ),
        ],
      ),
    );
  }

  /// Buat File Baru atau Folder Baru
  void _showCreateDialog({required bool isFolder}) {
    final nameCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isFolder ? 'Buat Folder Baru' : 'Buat File Baru'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: isFolder ? 'Nama Folder' : 'Nama File (contoh: script.sh)',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          FilledButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              final target = _currentPath == '/' ? '/$name' : '$_currentPath/$name';
              Navigator.pop(ctx);
              if (isFolder) {
                await widget.ssh.runCommand("mkdir -p '$target'");
                _loadDirectory(_currentPath);
              } else {
                await widget.ssh.writeFile(target, '');
                await _loadDirectory(_currentPath);
                _openFileEditor(
                  RemoteFileEntry(
                    name: name,
                    fullPath: target,
                    isDirectory: false,
                    isSymlink: false,
                    size: 0,
                    permissions: '-rw-r--r--',
                    octalPerm: '0644',
                    owner: 'root:root',
                    modified: 'Baru saja',
                  ),
                );
              }
            },
            child: const Text('Buat'),
          ),
        ],
      ),
    );
  }

  /// Upload File dari HP Android ke Direktori Aktif di OpenWrt
  Future<void> _uploadFileFromPhone() async {
    final picked = await FilePicker.platform.pickFiles(withData: true);
    if (picked == null || picked.files.isEmpty) return;

    final file = picked.files.first;
    final fileName = file.name;
    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null) {
      bytes = await File(file.path!).readAsBytes();
    }
    if (bytes == null) return;

    setState(() => _loading = true);
    try {
      final remoteDest = _currentPath == '/' ? '/$fileName' : '$_currentPath/$fileName';
      final sftp = await widget.ssh.getSftp();
      final remoteFile = await sftp.open(
        remoteDest,
        mode: SftpFileOpenMode.create | SftpFileOpenMode.truncate | SftpFileOpenMode.write,
      );
      await remoteFile.writeBytes(bytes);
      await remoteFile.close();

      await _loadDirectory(_currentPath);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('File "$fileName" berhasil diunggah ke $_currentPath'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal mengunggah file: $e'), backgroundColor: Colors.redAccent),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Buka Code Editor Penuh untuk Mengedit File di Sembarang Direktori
  Future<void> _openFileEditor(RemoteFileEntry item) async {
    setState(() => _loading = true);
    String content = '';
    try {
      content = await widget.ssh.readFile(item.fullPath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Tidak dapat membaca file: $e')),
        );
      }
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = false);
    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _FullCodeEditorPage(
          ssh: widget.ssh,
          fileEntry: item,
          initialContent: content,
        ),
      ),
    );
    _loadDirectory(_currentPath);
  }

  /// Dialog Rename / Pindahkan File atau Folder
  void _showRenameDialog(RemoteFileEntry item) {
    final ctrl = TextEditingController(text: item.fullPath);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Rename / Move: ${item.name}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Nama atau Path Baru',
            helperText: 'Ubah nama file atau ketik path direktori tujuan untuk memindahkan',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          FilledButton(
            onPressed: () async {
              final newPath = ctrl.text.trim();
              if (newPath.isEmpty || newPath == item.fullPath) return;
              Navigator.pop(ctx);
              await widget.ssh.renameItem(item.fullPath, newPath);
              _loadDirectory(_currentPath);
            },
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
  }

  /// Dialog Pengaturan Izin File Lengkap (CHMOD Visual Checkboxes + Octal + CHOWN)
  void _showPermissionsDialog(RemoteFileEntry item) {
    String octal = item.octalPerm.length == 4 ? item.octalPerm : '0${item.octalPerm}';
    int sp = int.tryParse(octal[0]) ?? 0;
    int u = int.tryParse(octal[1]) ?? 6;
    int g = int.tryParse(octal[2]) ?? 4;
    int o = int.tryParse(octal[3]) ?? 4;

    bool uR = (u & 4) != 0, uW = (u & 2) != 0, uX = (u & 1) != 0;
    bool gR = (g & 4) != 0, gW = (g & 2) != 0, gX = (g & 1) != 0;
    bool oR = (o & 4) != 0, oW = (o & 2) != 0, oX = (o & 1) != 0;
    bool setUid = (sp & 4) != 0, setGid = (sp & 2) != 0, sticky = (sp & 1) != 0;
    bool recursive = false;

    final octalCtrl = TextEditingController(text: octal);
    final ownerCtrl = TextEditingController(text: item.owner);

    void recalcOctal(void Function(void Function()) setDialogState) {
      final newSp = (setUid ? 4 : 0) + (setGid ? 2 : 0) + (sticky ? 1 : 0);
      final newU = (uR ? 4 : 0) + (uW ? 2 : 0) + (uX ? 1 : 0);
      final newG = (gR ? 4 : 0) + (gW ? 2 : 0) + (gX ? 1 : 0);
      final newO = (oR ? 4 : 0) + (oW ? 2 : 0) + (oX ? 1 : 0);
      setDialogState(() {
        octalCtrl.text = '$newSp$newU$newG$newO';
      });
    }

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Izin File (CHMOD & CHOWN)\n${item.name}', style: const TextStyle(fontSize: 15)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: octalCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Kode Oktal (CHMOD)',
                          helperText: 'Contoh: 0755, 0644, 0777',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (val) {
                          if (val.length >= 3) {
                            final padded = val.length == 3 ? '0$val' : val;
                            final sVal = int.tryParse(padded[0]) ?? 0;
                            final uVal = int.tryParse(padded[1]) ?? 0;
                            final gVal = int.tryParse(padded[2]) ?? 0;
                            final oVal = int.tryParse(padded[3]) ?? 0;
                            setDialogState(() {
                              setUid = (sVal & 4) != 0;
                              setGid = (sVal & 2) != 0;
                              sticky = (sVal & 1) != 0;
                              uR = (uVal & 4) != 0;
                              uW = (uVal & 2) != 0;
                              uX = (uVal & 1) != 0;
                              gR = (gVal & 4) != 0;
                              gW = (gVal & 2) != 0;
                              gX = (gVal & 1) != 0;
                              oR = (oVal & 4) != 0;
                              oW = (oVal & 2) != 0;
                              oX = (oVal & 1) != 0;
                            });
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: ownerCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Owner (CHOWN)',
                          helperText: 'root:root',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text('Matriks Izin Akses (R / W / X):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                Table(
                  defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                  children: [
                    const TableRow(
                      children: [
                        Text('Role', style: TextStyle(fontSize: 12, color: Colors.white60)),
                        Center(child: Text('Read (4)', style: TextStyle(fontSize: 11))),
                        Center(child: Text('Write (2)', style: TextStyle(fontSize: 11))),
                        Center(child: Text('Exec (1)', style: TextStyle(fontSize: 11))),
                      ],
                    ),
                    TableRow(
                      children: [
                        const Text('Owner', style: TextStyle(fontSize: 12)),
                        Checkbox(
                          value: uR,
                          onChanged: (v) {
                            uR = v ?? false;
                            recalcOctal(setDialogState);
                          },
                        ),
                        Checkbox(
                          value: uW,
                          onChanged: (v) {
                            uW = v ?? false;
                            recalcOctal(setDialogState);
                          },
                        ),
                        Checkbox(
                          value: uX,
                          onChanged: (v) {
                            uX = v ?? false;
                            recalcOctal(setDialogState);
                          },
                        ),
                      ],
                    ),
                    TableRow(
                      children: [
                        const Text('Group', style: TextStyle(fontSize: 12)),
                        Checkbox(
                          value: gR,
                          onChanged: (v) {
                            gR = v ?? false;
                            recalcOctal(setDialogState);
                          },
                        ),
                        Checkbox(
                          value: gW,
                          onChanged: (v) {
                            gW = v ?? false;
                            recalcOctal(setDialogState);
                          },
                        ),
                        Checkbox(
                          value: gX,
                          onChanged: (v) {
                            gX = v ?? false;
                            recalcOctal(setDialogState);
                          },
                        ),
                      ],
                    ),
                    TableRow(
                      children: [
                        const Text('Others', style: TextStyle(fontSize: 12)),
                        Checkbox(
                          value: oR,
                          onChanged: (v) {
                            oR = v ?? false;
                            recalcOctal(setDialogState);
                          },
                        ),
                        Checkbox(
                          value: oW,
                          onChanged: (v) {
                            oW = v ?? false;
                            recalcOctal(setDialogState);
                          },
                        ),
                        Checkbox(
                          value: oX,
                          onChanged: (v) {
                            oX = v ?? false;
                            recalcOctal(setDialogState);
                          },
                        ),
                      ],
                    ),
                  ],
                ),
                const Divider(),
                Wrap(
                  spacing: 6,
                  children: [
                    FilterChip(
                      label: const Text('SetUID (4)', style: TextStyle(fontSize: 11)),
                      selected: setUid,
                      onSelected: (v) {
                        setUid = v;
                        recalcOctal(setDialogState);
                      },
                    ),
                    FilterChip(
                      label: const Text('SetGID (2)', style: TextStyle(fontSize: 11)),
                      selected: setGid,
                      onSelected: (v) {
                        setGid = v;
                        recalcOctal(setDialogState);
                      },
                    ),
                    FilterChip(
                      label: const Text('Sticky (1)', style: TextStyle(fontSize: 11)),
                      selected: sticky,
                      onSelected: (v) {
                        sticky = v;
                        recalcOctal(setDialogState);
                      },
                    ),
                  ],
                ),
                if (item.isDirectory)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Terapkan ke seluruh sub-folder & isi (Recursive -R)'),
                    value: recursive,
                    onChanged: (v) => setDialogState(() => recursive = v ?? false),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
            FilledButton(
              onPressed: () async {
                final perm = octalCtrl.text.trim();
                final own = ownerCtrl.text.trim();
                final flag = (item.isDirectory && recursive) ? '-R ' : '';
                Navigator.pop(ctx);
                await widget.ssh.runCommand("chmod $flag$perm '${item.fullPath}'");
                if (own.isNotEmpty) {
                  await widget.ssh.runCommand("chown $flag$own '${item.fullPath}' 2>/dev/null || true");
                }
                _loadDirectory(_currentPath);
              },
              child: const Text('Terapkan Izin'),
            ),
          ],
        ),
      ),
    );
  }

  /// Menu Aksi Lengkap Saat Item Ditekan Lama / Klik Titik Tiga
  void _showItemActionsSheet(RemoteFileEntry item) {
    final isIpk = item.name.toLowerCase().endsWith('.ipk') || item.name.toLowerCase().endsWith('.apk');
    final isArchive = item.name.endsWith('.tar.gz') ||
        item.name.endsWith('.tgz') ||
        item.name.endsWith('.zip') ||
        item.name.endsWith('.tar');
    final isScript = item.name.endsWith('.sh') || item.permissions.contains('x');

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: Icon(item.isDirectory ? Icons.folder : Icons.insert_drive_file, color: Colors.lightBlueAccent),
              title: Text(item.name, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('${item.fullPath}\nPerm: ${item.permissions} (${item.octalPerm}) • Size: ${_formatSize(item.size)}'),
              isThreeLine: true,
            ),
            const Divider(height: 1),
            if (!item.isDirectory)
              ListTile(
                leading: const Icon(Icons.edit_note),
                title: const Text('Edit File (Code Editor)'),
                onTap: () {
                  Navigator.pop(ctx);
                  _openFileEditor(item);
                },
              ),
            if (isIpk)
              ListTile(
                leading: const Icon(Icons.install_mobile, color: Colors.greenAccent),
                title: const Text('Instal Paket IPK/APK Ini Sekarang'),
                onTap: () async {
                  Navigator.pop(ctx);
                  _installPackageFile(item.fullPath);
                },
              ),
            if (isScript && !item.isDirectory)
              ListTile(
                leading: const Icon(Icons.play_circle_fill, color: Colors.tealAccent),
                title: const Text('Jalankan Script / Binary Ini'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final out = await widget.ssh.runCommand("sh '${item.fullPath}' 2>&1 || '${item.fullPath}' 2>&1");
                  if (!mounted) return;
                  showDialog(
                    context: context,
                    builder: (dCtx) => AlertDialog(
                      title: Text('Output: ${item.name}'),
                      content: SingleChildScrollView(
                        child: SelectableText(out.isEmpty ? '(Selesai tanpa output)' : out,
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(dCtx), child: const Text('Tutup')),
                      ],
                    ),
                  );
                },
              ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename / Pindahkan'),
              onTap: () {
                Navigator.pop(ctx);
                _showRenameDialog(item);
              },
            ),
            ListTile(
              leading: const Icon(Icons.security, color: Colors.amberAccent),
              title: Text('Setting Izin File / CHMOD (${item.octalPerm})'),
              onTap: () {
                Navigator.pop(ctx);
                _showPermissionsDialog(item);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Salin (Copy) ke Clipboard'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _clipboardPath = item.fullPath;
                  _clipboardIsCut = false;
                });
              },
            ),
            ListTile(
              leading: const Icon(Icons.content_cut),
              title: const Text('Potong (Cut) ke Clipboard'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _clipboardPath = item.fullPath;
                  _clipboardIsCut = true;
                });
              },
            ),
            if (isArchive)
              ListTile(
                leading: const Icon(Icons.unarchive),
                title: const Text('Ekstrak Arsip di Sini'),
                onTap: () async {
                  Navigator.pop(ctx);
                  if (item.name.endsWith('.zip')) {
                    await widget.ssh.runCommand("unzip -o '${item.fullPath}' -d '$_currentPath'");
                  } else {
                    await widget.ssh.runCommand("tar -xzf '${item.fullPath}' -C '$_currentPath' || tar -xf '${item.fullPath}' -C '$_currentPath'");
                  }
                  _loadDirectory(_currentPath);
                },
              ),
            if (item.isDirectory)
              ListTile(
                leading: const Icon(Icons.archive),
                title: const Text('Kompres Folder ke .tar.gz'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await widget.ssh.runCommand("cd '$_currentPath' && tar -czf '${item.name}.tar.gz' '${item.name}'");
                  _loadDirectory(_currentPath);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_forever, color: Colors.redAccent),
              title: const Text('Hapus Permanen', style: TextStyle(color: Colors.redAccent)),
              onTap: () {
                Navigator.pop(ctx);
                showDialog(
                  context: context,
                  builder: (dCtx) => AlertDialog(
                    title: const Text('Konfirmasi Hapus'),
                    content: Text('Yakin ingin menghapus "${item.fullPath}"?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(dCtx), child: const Text('Batal')),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                        onPressed: () async {
                          Navigator.pop(dCtx);
                          await widget.ssh.deleteItem(item.fullPath, isDirectory: item.isDirectory);
                          _loadDirectory(_currentPath);
                        },
                        child: const Text('Hapus'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _installPackageFile(String fullPath) async {
    setState(() => _loading = true);
    try {
      final out = await widget.ssh.runCommand(
        "opkg install --force-overwrite '$fullPath' 2>&1 || apk add --allow-untrusted '$fullPath' 2>&1",
      );
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Hasil Instalasi Paket'),
          content: SingleChildScrollView(
            child: SelectableText(out, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Selesai')),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pasteClipboardItem() async {
    if (_clipboardPath == null) return;
    setState(() => _loading = true);
    try {
      if (_clipboardIsCut) {
        await widget.ssh.runCommand("mv '$_clipboardPath' '$_currentPath/'");
      } else {
        await widget.ssh.runCommand("cp -r '$_clipboardPath' '$_currentPath/'");
      }
      _clipboardPath = null;
      await _loadDirectory(_currentPath);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibleEntries = _entries.where((e) {
      if (_searchQuery.isEmpty) return true;
      return e.name.toLowerCase().contains(_searchQuery.toLowerCase());
    }).toList();

    return Column(
      children: [
        // Baris Navigasi Path & Tombol Operasi Cepat
        Container(
          color: const Color(0xFF1B222D),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_upward, size: 20),
                    tooltip: 'Naik ke Direktori Induk (..)',
                    onPressed: _currentPath == '/' ? null : _navigateUp,
                  ),
                  Expanded(
                    child: InkWell(
                      onTap: _showJumpPathDialog,
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black38,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.folder_special, size: 16, color: Colors.lightBlueAccent),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                _currentPath,
                                style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 13),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const Icon(Icons.edit_location_alt, size: 16, color: Colors.white54),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (_clipboardPath != null)
                    IconButton(
                      icon: const Icon(Icons.content_paste, color: Colors.greenAccent),
                      tooltip: 'Tempel (Paste) di Sini',
                      onPressed: _pasteClipboardItem,
                    ),
                  IconButton(
                    icon: const Icon(Icons.upload_file),
                    tooltip: 'Upload File / IPK dari HP',
                    onPressed: _uploadFileFromPhone,
                  ),
                  IconButton(
                    icon: const Icon(Icons.create_new_folder_outlined),
                    tooltip: 'Folder Baru',
                    onPressed: () => _showCreateDialog(isFolder: true),
                  ),
                  IconButton(
                    icon: const Icon(Icons.note_add_outlined),
                    tooltip: 'File Baru',
                    onPressed: () => _showCreateDialog(isFolder: false),
                  ),
                  IconButton(
                    icon: _loading
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh),
                    onPressed: () => _loadDirectory(_currentPath),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // Baris Bookmark Cepat Semua Direktori Penting
              SizedBox(
                height: 30,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _quickBookmarks.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (ctx, idx) {
                    final bm = _quickBookmarks[idx];
                    final isCurrent = _currentPath == bm['path'];
                    return ActionChip(
                      visualDensity: VisualDensity.compact,
                      backgroundColor: isCurrent ? const Color(0xFF0077B5) : Colors.black26,
                      label: Text(bm['label']!, style: const TextStyle(fontSize: 11)),
                      onPressed: () => _loadDirectory(bm['path']!),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        // Baris Pencarian & Header Kolom (Name | Size | Modified | Perm)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          color: Colors.black26,
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: 'Filter nama file/folder di direktori ini...',
                      prefixIcon: Icon(Icons.search, size: 18),
                      contentPadding: EdgeInsets.zero,
                      border: OutlineInputBorder(),
                    ),
                    style: const TextStyle(fontSize: 12),
                    onChanged: (v) => setState(() => _searchQuery = v),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              PopupMenuButton<String>(
                icon: const Icon(Icons.sort, size: 20),
                tooltip: 'Urutkan (Sort)',
                onSelected: (val) {
                  setState(() {
                    if (_sortBy == val) {
                      _sortAsc = !_sortAsc;
                    } else {
                      _sortBy = val;
                      _sortAsc = true;
                    }
                    _sortEntries(_entries);
                  });
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'name', child: Text('Urutkan: Nama')),
                  PopupMenuItem(value: 'size', child: Text('Urutkan: Ukuran (Size)')),
                  PopupMenuItem(value: 'modified', child: Text('Urutkan: Waktu (Modified)')),
                ],
              ),
            ],
          ),
        ),
        // Daftar File & Direktori
        Expanded(
          child: visibleEntries.isEmpty
              ? Center(
                  child: Text(
                    _loading ? 'Memuat isi direktori...' : 'Direktori kosong atau tidak ada hasil pencarian.',
                    style: const TextStyle(color: Colors.white54),
                  ),
                )
              : ListView.separated(
                  itemCount: visibleEntries.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white10),
                  itemBuilder: (ctx, i) {
                    final item = visibleEntries[i];
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        item.isDirectory
                            ? Icons.folder
                            : (item.name.endsWith('.ipk')
                                ? Icons.archive
                                : (item.permissions.contains('x') ? Icons.terminal : Icons.description)),
                        color: item.isDirectory
                            ? Colors.amber
                            : (item.name.endsWith('.ipk')
                                ? Colors.greenAccent
                                : (item.permissions.contains('x') ? Colors.tealAccent : Colors.lightBlueAccent)),
                      ),
                      title: Text(
                        item.name,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                      ),
                      subtitle: Text(
                        '${item.isDirectory ? 'Folder' : _formatSize(item.size)}  •  ${item.modified}  •  ${item.octalPerm} (${item.permissions})',
                        style: const TextStyle(fontSize: 11, color: Colors.white60),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.security, size: 18, color: Colors.white70),
                            tooltip: 'Setting Izin (CHMOD)',
                            onPressed: () => _showPermissionsDialog(item),
                          ),
                          IconButton(
                            icon: const Icon(Icons.more_vert, size: 18),
                            onPressed: () => _showItemActionsSheet(item),
                          ),
                        ],
                      ),
                      onTap: () {
                        if (item.isDirectory) {
                          _loadDirectory(item.fullPath);
                        } else if (item.name.toLowerCase().endsWith('.ipk')) {
                          _showItemActionsSheet(item);
                        } else {
                          _openFileEditor(item);
                        }
                      },
                      onLongPress: () => _showItemActionsSheet(item),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Halaman Code Editor Internal untuk Mengedit File di Semua Direktori
class _FullCodeEditorPage extends StatefulWidget {
  final SshService ssh;
  final RemoteFileEntry fileEntry;
  final String initialContent;

  const _FullCodeEditorPage({
    required this.ssh,
    required this.fileEntry,
    required this.initialContent,
  });

  @override
  State<_FullCodeEditorPage> createState() => _FullCodeEditorPageState();
}

class _FullCodeEditorPageState extends State<_FullCodeEditorPage> {
  late TextEditingController _codeCtrl;
  bool _saving = false;
  bool _createBackup = false;
  bool _wordWrap = true;

  @override
  void initState() {
    super.initState();
    _codeCtrl = TextEditingController(text: widget.initialContent);
  }

  Future<void> _saveFile() async {
    setState(() => _saving = true);
    try {
      if (_createBackup) {
        await widget.ssh.runCommand("cp '${widget.fileEntry.fullPath}' '${widget.fileEntry.fullPath}.bak'");
      }
      await widget.ssh.writeFile(widget.fileEntry.fullPath, _codeCtrl.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('File ${widget.fileEntry.fullPath} berhasil disimpan!'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal menyimpan file: $e'), backgroundColor: Colors.redAccent),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showSearchReplaceDialog() {
    final findCtrl = TextEditingController();
    final repCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cari & Ganti Teks (Find & Replace)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: findCtrl, decoration: const InputDecoration(labelText: 'Cari kata/baris')),
            const SizedBox(height: 8),
            TextField(controller: repCtrl, decoration: const InputDecoration(labelText: 'Ganti dengan')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          FilledButton(
            onPressed: () {
              final f = findCtrl.text;
              if (f.isNotEmpty) {
                setState(() {
                  _codeCtrl.text = _codeCtrl.text.replaceAll(f, repCtrl.text);
                });
              }
              Navigator.pop(ctx);
            },
            child: const Text('Replace All'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.fileEntry.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            Text(widget.fileEntry.fullPath, style: const TextStyle(fontSize: 11, color: Colors.white70)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.find_replace),
            tooltip: 'Find & Replace',
            onPressed: _showSearchReplaceDialog,
          ),
          IconButton(
            icon: Icon(_wordWrap ? Icons.wrap_text : Icons.notes),
            tooltip: 'Toggle Word Wrap',
            onPressed: () => setState(() => _wordWrap = !_wordWrap),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              onPressed: _saving ? null : _saveFile,
              icon: _saving
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save, size: 18),
              label: const Text('SAVE'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            color: Colors.black26,
            child: Row(
              children: [
                Text('Perm: ${widget.fileEntry.octalPerm}', style: const TextStyle(fontSize: 12, color: Colors.white70)),
                const Spacer(),
                Checkbox(
                  visualDensity: VisualDensity.compact,
                  value: _createBackup,
                  onChanged: (v) => setState(() => _createBackup = v ?? false),
                ),
                const Text('Buat .bak saat simpan', style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: TextField(
                controller: _codeCtrl,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.4),
                decoration: const InputDecoration(
                  filled: true,
                  fillColor: Color(0xFF0D1117),
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
