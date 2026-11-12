import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TextCastApp());
}

class TextCastApp extends StatelessWidget {
  const TextCastApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TextCast',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00ADB5),
          brightness: Brightness.light,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00ADB5),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF12141E),
      ),
      home: const TextCastHomePage(),
    );
  }
}

class DiscoveredServer {
  final String name;
  final String ip;
  final int port;
  DateTime lastSeen;

  DiscoveredServer({
    required this.name,
    required this.ip,
    required this.port,
    required this.lastSeen,
  });

  String get id => '$ip:$port';
}

enum SyncDirection {
  pcToPhone,
  phoneToPc,
}

class ClipboardItem {
  final String text;
  final DateTime timestamp;
  final SyncDirection direction;

  ClipboardItem({
    required this.text,
    required this.timestamp,
    required this.direction,
  });
}

enum ConnectionStatus {
  disconnected,
  connecting,
  connected,
}

class TextCastHomePage extends StatefulWidget {
  const TextCastHomePage({super.key});

  @override
  State<TextCastHomePage> createState() => _TextCastHomePageState();
}

class _TextCastHomePageState extends State<TextCastHomePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const String _prefIpKey = 'pc_server_ip';
  static const int _discoveryPort = 8766;
  static const int _defaultWsPort = 8765;

  final TextEditingController _manualIpController = TextEditingController();
  final TextEditingController _quickSendController = TextEditingController();
  final List<ClipboardItem> _history = [];
  final Map<String, DiscoveredServer> _discoveredServers = {};

  RawDatagramSocket? _discoverySocket;
  RawDatagramSocket? _beaconListenerSocket;
  Timer? _probeTimer;
  Timer? _cleanupTimer;
  Timer? _clipboardPollTimer;
  bool _isScanning = false;

  WebSocketChannel? _channel;
  StreamSubscription? _channelSubscription;
  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;
  DiscoveredServer? _connectedServer;
  bool _manualDisconnect = false;
  Timer? _reconnectTimer;
  bool _showManualEntry = false;
  bool _autoSyncPhoneClipboard = true;

  // Echo suppression tokens to prevent loopback
  String _lastReceivedFromPc = '';
  String _lastSentToPc = '';

  static const MethodChannel _settingsChannel = MethodChannel('com.textcast.mobile_app/settings');
  bool _isAccessibilityEnabled = false;

  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _loadSavedIp();
    _checkAccessibilityStatus();
    _startWifiScan();
    _startClipboardWatcher();
  }

  Future<void> _checkAccessibilityStatus() async {
    try {
      final bool? enabled = await _settingsChannel.invokeMethod<bool>('isAccessibilityEnabled');
      if (mounted && enabled != null) {
        setState(() {
          _isAccessibilityEnabled = enabled;
        });
      }
    } catch (_) {}
  }

  Future<void> _openAccessibilitySettings() async {
    try {
      await _settingsChannel.invokeMethod('openAccessibilitySettings');
    } catch (e) {
      _showSnackBar('Cannot open Accessibility settings: $e', isError: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulseController.dispose();
    _stopWifiScan();
    _clipboardPollTimer?.cancel();
    _reconnectTimer?.cancel();
    _cleanupChannel();
    _manualIpController.dispose();
    _quickSendController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAccessibilityStatus();
      if (_autoSyncPhoneClipboard) {
        Future.delayed(const Duration(milliseconds: 200), () {
          if (mounted && _connectionStatus == ConnectionStatus.connected) {
            _checkPhoneClipboard();
          }
        });
      }
    }
  }

  Future<void> _loadSavedIp() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedIp = prefs.getString(_prefIpKey) ?? '';
      if (savedIp.isNotEmpty) {
        setState(() {
          _manualIpController.text = savedIp;
        });
      }
    } catch (e) {
      debugPrint('Error loading saved IP: $e');
    }
  }

  Future<void> _saveIp(String ip) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefIpKey, ip.trim());
    } catch (e) {
      debugPrint('Error saving IP: $e');
    }
  }

  // ===================== BIDIRECTIONAL CLIPBOARD ENGINE =====================

  void _startClipboardWatcher() {
    _clipboardPollTimer?.cancel();
    // Polls clipboard every 750ms while app is open and connected to detect phone copy
    _clipboardPollTimer = Timer.periodic(const Duration(milliseconds: 750), (_) {
      if (_autoSyncPhoneClipboard && _connectionStatus == ConnectionStatus.connected) {
        _checkPhoneClipboard();
      }
    });
  }

  Future<void> _checkPhoneClipboard() async {
    if (_connectionStatus != ConnectionStatus.connected) return;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) return;

      // Echo suppression: only sync if different from last received from PC and last sent to PC
      if (text != _lastReceivedFromPc && text != _lastSentToPc) {
        _sendTextToPc(text, fromAutoDetect: true);
      }
    } catch (_) {}
  }

  Future<void> _sendTextToPc(String text, {bool fromAutoDetect = false}) async {
    if (_connectionStatus != ConnectionStatus.connected || _channel == null) {
      _showSnackBar('Not connected to PC', isError: true);
      return;
    }

    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    _lastSentToPc = trimmed;

    try {
      _channel?.sink.add(trimmed);

      setState(() {
        _history.insert(
          0,
          ClipboardItem(
            text: trimmed,
            timestamp: DateTime.now(),
            direction: SyncDirection.phoneToPc,
          ),
        );
      });

      final preview = trimmed.length > 35 ? '${trimmed.substring(0, 32)}...' : trimmed;
      _showSnackBar(fromAutoDetect ? 'Phone copy synced to PC: "$preview"' : 'Sent to PC clipboard: "$preview"');
    } catch (e) {
      _showSnackBar('Failed to send text to PC: $e', isError: true);
    }
  }

  Future<void> _sendCurrentPhoneClipboardManual() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) {
        _showSnackBar('Phone clipboard is currently empty', isError: true);
        return;
      }
      await _sendTextToPc(text, fromAutoDetect: false);
    } catch (e) {
      _showSnackBar('Error reading clipboard: $e', isError: true);
    }
  }

  // ===================== WI-FI DISCOVERY ENGINE =====================

  void _startWifiScan() async {
    _stopWifiScan();
    if (!mounted) return;

    setState(() {
      _isScanning = true;
    });

    try {
      // 1. Bind discovery socket for active probe broadcasts and unicast replies
      _discoverySocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _discoverySocket?.broadcastEnabled = true;

      _discoverySocket?.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = _discoverySocket?.receive();
          if (datagram != null) {
            _handleDiscoveryPacket(datagram);
          }
        }
      });

      // 2. Also try binding beacon listener on 8766 to catch periodic server broadcasts
      try {
        _beaconListenerSocket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          _discoveryPort,
          reuseAddress: true,
          reusePort: true,
        );
        _beaconListenerSocket?.broadcastEnabled = true;
        _beaconListenerSocket?.listen((RawSocketEvent event) {
          if (event == RawSocketEvent.read) {
            final datagram = _beaconListenerSocket?.receive();
            if (datagram != null) {
              _handleDiscoveryPacket(datagram);
            }
          }
        });
      } catch (e) {
        debugPrint('Beacon listener bind note: $e');
      }

      // 3. Send initial probe immediately
      _sendDiscoveryProbe();

      // 4. Send probe every 1.8 seconds while scanning
      _probeTimer = Timer.periodic(const Duration(milliseconds: 1800), (_) {
        _sendDiscoveryProbe();
      });

      // 5. Periodic cleanup of stale servers (inactive for > 10 seconds)
      _cleanupTimer = Timer.periodic(const Duration(seconds: 4), (_) {
        final now = DateTime.now();
        final staleIds = <String>[];
        _discoveredServers.forEach((key, server) {
          if (now.difference(server.lastSeen).inSeconds > 10) {
            staleIds.add(key);
          }
        });
        if (staleIds.isNotEmpty && mounted) {
          setState(() {
            for (final id in staleIds) {
              _discoveredServers.remove(id);
            }
          });
        }
      });
    } catch (e) {
      debugPrint('Error initiating Wi-Fi scan: $e');
      if (mounted) {
        setState(() {
          _isScanning = false;
        });
      }
    }
  }

  Future<void> _sendDiscoveryProbe() async {
    if (_discoverySocket == null) return;
    const probeMessage = '{"cmd":"TEXTCAST_DISCOVER"}';
    final bytes = utf8.encode(probeMessage);

    try {
      // Broadcast to universal broadcast address
      _discoverySocket?.send(
        bytes,
        InternetAddress('255.255.255.255'),
        _discoveryPort,
      );

      // Also broadcast to each local interface subnet broadcast (e.g. 192.168.1.255)
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length == 4) {
            final subnetBroadcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
            try {
              _discoverySocket?.send(
                bytes,
                InternetAddress(subnetBroadcast),
                _discoveryPort,
              );
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      debugPrint('Error sending discovery probe: $e');
    }
  }

  void _handleDiscoveryPacket(Datagram datagram) {
    try {
      final raw = utf8.decode(datagram.data).trim();
      final data = jsonDecode(raw) as Map<String, dynamic>;

      if (data['service'] == 'textcast') {
        final name = data['name']?.toString() ?? 'PC Server';
        var ip = data['ip']?.toString() ?? '';
        if (ip.isEmpty || ip == '0.0.0.0' || ip == '127.0.0.1') {
          ip = datagram.address.address;
        }
        final port = (data['port'] as num?)?.toInt() ?? _defaultWsPort;

        final server = DiscoveredServer(
          name: name,
          ip: ip,
          port: port,
          lastSeen: DateTime.now(),
        );

        if (mounted) {
          setState(() {
            _discoveredServers[server.id] = server;
          });
        }
      }
    } catch (e) {
      // Ignore non-json or unrelated datagrams
    }
  }

  void _stopWifiScan() {
    _probeTimer?.cancel();
    _probeTimer = null;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    try {
      _discoverySocket?.close();
    } catch (_) {}
    _discoverySocket = null;
    try {
      _beaconListenerSocket?.close();
    } catch (_) {}
    _beaconListenerSocket = null;
    if (mounted) {
      setState(() {
        _isScanning = false;
      });
    }
  }

  // ===================== WEBSOCKET CONNECTION =====================

  void _cleanupChannel() {
    _channelSubscription?.cancel();
    _channelSubscription = null;
    try {
      _channel?.sink.close(ws_status.goingAway);
    } catch (_) {}
    _channel = null;
  }

  void _connectToServer(DiscoveredServer server) {
    _connect(server.ip, server.port, serverName: server.name);
  }

  void _connectManual() {
    final input = _manualIpController.text.trim();
    if (input.isEmpty) {
      _showSnackBar('Please enter your PC IPv4 address', isError: true);
      return;
    }
    var cleanIp = input.replaceAll('http://', '').replaceAll('ws://', '').replaceAll('/', '');
    int port = _defaultWsPort;
    if (cleanIp.contains(':')) {
      final parts = cleanIp.split(':');
      cleanIp = parts[0];
      port = int.tryParse(parts[1]) ?? _defaultWsPort;
    }
    _connect(cleanIp, port, serverName: 'PC Server');
  }

  void _connect(String ip, int port, {String serverName = 'PC Server'}) async {
    await _saveIp(ip);
    _manualDisconnect = false;
    _reconnectTimer?.cancel();

    setState(() {
      _connectionStatus = ConnectionStatus.connecting;
      _connectedServer = DiscoveredServer(
        name: serverName,
        ip: ip,
        port: port,
        lastSeen: DateTime.now(),
      );
    });

    _cleanupChannel();
    final wsUri = Uri.parse('ws://$ip:$port');

    try {
      final channel = WebSocketChannel.connect(wsUri);
      _channel = channel;

      _channelSubscription = channel.stream.listen(
        (data) {
          if (_connectionStatus != ConnectionStatus.connected) {
            setState(() {
              _connectionStatus = ConnectionStatus.connected;
            });
            _showSnackBar('Connected to $serverName ($ip)');
          }
          _handleIncomingTextFromPc(data.toString());
        },
        onError: (error) {
          debugPrint('WebSocket error: $error');
          _handleDisconnection('Connection error: $error');
        },
        onDone: () {
          debugPrint('WebSocket closed');
          _handleDisconnection('Disconnected from server');
        },
        cancelOnError: true,
      );

      setState(() {
        _connectionStatus = ConnectionStatus.connected;
      });
      _showSnackBar('Connected to $serverName ($ip)');

      // Immediately check and auto-sync phone clipboard on connection
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted && _connectionStatus == ConnectionStatus.connected) {
          _checkPhoneClipboard();
        }
      });
    } catch (e) {
      _handleDisconnection('Failed to connect: $e');
    }
  }

  void _disconnect() {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _cleanupChannel();
    setState(() {
      _connectionStatus = ConnectionStatus.disconnected;
      _connectedServer = null;
    });
    _showSnackBar('Disconnected from PC server');
    _startWifiScan();
  }

  void _handleDisconnection(String reason) {
    if (_connectionStatus == ConnectionStatus.disconnected && _manualDisconnect) {
      return;
    }

    _cleanupChannel();

    if (mounted) {
      setState(() {
        _connectionStatus = ConnectionStatus.disconnected;
      });
      _showSnackBar(reason, isError: true);
    }

    // Auto-reconnect if not manually disconnected
    if (!_manualDisconnect && _connectedServer != null) {
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(const Duration(seconds: 4), () {
        if (!_manualDisconnect && mounted && _connectionStatus == ConnectionStatus.disconnected && _connectedServer != null) {
          _connectToServer(_connectedServer!);
        }
      });
    }
  }

  Future<void> _handleIncomingTextFromPc(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    // Echo suppression tracking: remember this came from PC
    _lastReceivedFromPc = trimmed;
    _lastSentToPc = trimmed;

    // 1. Copy directly to Android system clipboard
    await Clipboard.setData(ClipboardData(text: trimmed));

    // 2. Prepend to history
    setState(() {
      _history.insert(
        0,
        ClipboardItem(
          text: trimmed,
          timestamp: DateTime.now(),
          direction: SyncDirection.pcToPhone,
        ),
      );
    });

    // 3. Show confirmation SnackBar
    final preview = trimmed.length > 35 ? '${trimmed.substring(0, 32)}...' : trimmed;
    _showSnackBar('PC copy synced to phone: "$preview"');
  }

  Future<void> _copyItem(ClipboardItem item) async {
    await Clipboard.setData(ClipboardData(text: item.text));
    HapticFeedback.lightImpact();
    final preview = item.text.length > 35 ? '${item.text.substring(0, 32)}...' : item.text;
    _showSnackBar('Copied to clipboard: "$preview"');
  }

  void _clearHistory() {
    if (_history.isEmpty) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear History'),
        content: const Text('Are you sure you want to remove all saved clipboard entries?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _history.clear();
              });
              _showSnackBar('Clipboard history cleared');
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).colorScheme.primaryContainer,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final second = dt.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  // ===================== UI BUILD =====================

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isConnected = _connectionStatus == ConnectionStatus.connected;
    final isConnecting = _connectionStatus == ConnectionStatus.connecting;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.sync_alt_rounded,
                color: colorScheme.onPrimaryContainer,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'TextCast 2-Way',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          if (!isConnected)
            IconButton(
              icon: Icon(_isScanning ? Icons.sync_rounded : Icons.radar_rounded),
              tooltip: _isScanning ? 'Scanning Wi-Fi...' : 'Scan for PC',
              onPressed: _startWifiScan,
            ),
          if (_history.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Clear History',
              onPressed: _clearHistory,
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Top Section: Either Active 2-Way Connection Card OR Wi-Fi PC Discovery Section
            if (isConnected)
              _buildConnectedCard(theme, colorScheme)
            else
              _buildDiscoverySection(theme, colorScheme, isConnecting),

            // History Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Clipboard History (${_history.length})',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (isConnected)
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.greenAccent,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '2-Way Sync Active',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.greenAccent,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),

            // History List or Empty View
            Expanded(
              child: _history.isEmpty
                  ? _buildEmptyState(theme, colorScheme, isConnected)
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      itemCount: _history.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final item = _history[index];
                        return _buildHistoryCard(context, item, index);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectedCard(ThemeData theme, ColorScheme colorScheme) {
    final serverName = _connectedServer?.name ?? 'PC Server';
    final serverIp = _connectedServer?.ip ?? '';
    final serverPort = _connectedServer?.port ?? _defaultWsPort;

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.green.withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.devices_rounded,
                    color: Colors.green,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              serverName,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.green.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              'PC ↔ PHONE',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: Colors.green,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '$serverIp:$serverPort',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _disconnect,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colorScheme.error,
                    side: BorderSide(color: colorScheme.error.withValues(alpha: 0.5)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  ),
                  icon: const Icon(Icons.link_off_rounded, size: 16),
                  label: const Text('Disconnect', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const Divider(height: 20),

            // System-Wide Background Copy Setup / Status Card
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _isAccessibilityEnabled
                    ? Colors.green.withValues(alpha: 0.12)
                    : colorScheme.primaryContainer.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _isAccessibilityEnabled
                      ? Colors.green.withValues(alpha: 0.3)
                      : colorScheme.primary.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _isAccessibilityEnabled ? Icons.check_circle_rounded : Icons.flash_on_rounded,
                    color: _isAccessibilityEnabled ? Colors.green : colorScheme.primary,
                    size: 26,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _isAccessibilityEnabled
                              ? 'System-Wide Auto-Copy Active'
                              : 'Auto-Copy from Any App',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: _isAccessibilityEnabled ? Colors.green : colorScheme.primary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _isAccessibilityEnabled
                              ? 'Text copied anywhere on your phone (Chrome, WhatsApp, etc.) is automatically beamed to your PC clipboard!'
                              : 'Enable TextCast in Accessibility to automatically copy from all apps without opening TextCast.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 11,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!_isAccessibilityEnabled)
                    FilledButton.tonal(
                      onPressed: _openAccessibilitySettings,
                      style: FilledButton.styleFrom(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      ),
                      child: const Text('Enable', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.autorenew_rounded,
                      size: 18,
                      color: _autoSyncPhoneClipboard ? Colors.greenAccent : colorScheme.outline,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Auto-Sync Phone Copy to PC',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _autoSyncPhoneClipboard ? colorScheme.onSurface : colorScheme.outline,
                      ),
                    ),
                  ],
                ),
                Switch(
                  value: _autoSyncPhoneClipboard,
                  onChanged: (val) {
                    setState(() {
                      _autoSyncPhoneClipboard = val;
                    });
                    _showSnackBar(val
                        ? 'Auto-sync from phone to PC enabled'
                        : 'Auto-sync from phone to PC paused');
                  },
                ),
              ],
            ),
            const SizedBox(height: 6),

            // Two-Way Quick Action Row: Send Phone Clipboard to PC!
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _sendCurrentPhoneClipboardManual,
                    style: FilledButton.styleFrom(
                      backgroundColor: colorScheme.primary,
                      foregroundColor: colorScheme.onPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                    ),
                    icon: const Icon(Icons.upload_rounded, size: 18),
                    label: const Text(
                      'Send Phone Clipboard to PC',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Quick Send custom input
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _quickSendController,
                    decoration: InputDecoration(
                      hintText: 'Type text to send to PC...',
                      hintStyle: TextStyle(fontSize: 12, color: colorScheme.outline),
                      isDense: true,
                      filled: true,
                      fillColor: theme.cardColor.withValues(alpha: 0.6),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    onSubmitted: (val) {
                      if (val.trim().isNotEmpty) {
                        _sendTextToPc(val.trim());
                        _quickSendController.clear();
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  icon: const Icon(Icons.send_rounded, size: 18),
                  tooltip: 'Beam to PC Clipboard',
                  style: IconButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () {
                    final text = _quickSendController.text.trim();
                    if (text.isNotEmpty) {
                      _sendTextToPc(text);
                      _quickSendController.clear();
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiscoverySection(
    ThemeData theme,
    ColorScheme colorScheme,
    bool isConnecting,
  ) {
    final servers = _discoveredServers.values.toList();

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with scan indicator
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.wifi_find_rounded,
                      size: 20,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Wi-Fi PC Detection',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                if (_isScanning)
                  Row(
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Scanning...',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  )
                else
                  TextButton.icon(
                    onPressed: _startWifiScan,
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Rescan'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // Discovered Servers List
            if (servers.isNotEmpty) ...[
              Column(
                children: servers.map((server) {
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: colorScheme.primary.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.desktop_windows_rounded,
                            color: colorScheme.onPrimaryContainer,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                server.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${server.ip}:${server.port}',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: isConnecting
                              ? null
                              : () => _connectToServer(server),
                          style: FilledButton.styleFrom(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                          ),
                          icon: isConnecting
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.link_rounded, size: 18),
                          label: Text(isConnecting ? 'Connecting' : 'Connect'),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ] else ...[
              // Scanning / No PC detected status
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    FadeTransition(
                      opacity: _pulseController,
                      child: Icon(
                        Icons.wifi_tethering_rounded,
                        size: 36,
                        color: colorScheme.primary.withValues(alpha: 0.7),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _isScanning
                          ? 'Searching Wi-Fi for your PC...'
                          : 'No TextCast PC detected yet',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Ensure TextCast Server is running on your PC and both devices are connected to the same Wi-Fi.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Fallback: Collapsible Manual IP Entry
            const SizedBox(height: 8),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                setState(() {
                  _showManualEntry = !_showManualEntry;
                });
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _showManualEntry ? 'Hide Manual IP' : 'Enter IP Manually',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Icon(
                      _showManualEntry
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 16,
                      color: colorScheme.primary,
                    ),
                  ],
                ),
              ),
            ),

            if (_showManualEntry) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _manualIpController,
                      keyboardType: TextInputType.datetime,
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(
                        labelText: 'PC Server IP Address',
                        hintText: 'e.g. 192.168.1.100',
                        prefixIcon: const Icon(Icons.lan_rounded),
                        suffixText: ':$_defaultWsPort',
                        filled: true,
                        fillColor: theme.cardColor.withValues(alpha: 0.5),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                      onSubmitted: (_) => _connectManual(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: isConnecting ? null : _connectManual,
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                    child: const Text('Connect'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryCard(BuildContext context, ClipboardItem item, int index) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isFromPc = item.direction == SyncDirection.pcToPhone;

    return Card(
      elevation: 0.5,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isFromPc
              ? colorScheme.outlineVariant.withValues(alpha: 0.4)
              : Colors.purple.withValues(alpha: 0.3),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _copyItem(item),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: isFromPc
                              ? colorScheme.primaryContainer
                              : Colors.purple.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isFromPc ? Icons.laptop_chromebook_rounded : Icons.smartphone_rounded,
                              size: 13,
                              color: isFromPc ? colorScheme.onPrimaryContainer : Colors.purpleAccent,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              isFromPc ? 'PC ➔ Phone' : 'Phone ➔ PC',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: isFromPc ? colorScheme.onPrimaryContainer : Colors.purpleAccent,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _formatTime(item.timestamp),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Text(
                        '${item.text.length} chars',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.outline,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(width: 6),
                      // Beam to PC button
                      IconButton(
                        icon: const Icon(Icons.upload_rounded, size: 18),
                        tooltip: 'Send to PC Clipboard',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () => _sendTextToPc(item.text),
                      ),
                      const SizedBox(width: 8),
                      // Copy to phone button
                      IconButton(
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        tooltip: 'Copy to Phone',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () => _copyItem(item),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SelectableText(
                item.text,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.4,
                ),
                maxLines: 6,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme, ColorScheme colorScheme, bool isConnected) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colorScheme.primaryContainer.withValues(alpha: 0.4),
              ),
              child: Icon(
                isConnected ? Icons.sync_alt_rounded : Icons.wifi_off_rounded,
                size: 56,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              isConnected ? '2-Way Sync Active!' : 'Not Connected',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              isConnected
                  ? '• Press Ctrl+C on PC -> instantly copies to this phone.\n• Copy any text on your phone -> instantly copied to your PC clipboard!'
                  : 'Start TextCast Server on your PC. When it appears in the detected list above, tap Connect.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
