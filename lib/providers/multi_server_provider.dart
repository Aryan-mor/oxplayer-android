import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/plex_client.dart';
import '../services/data_aggregation_service.dart';
import '../services/multi_server_manager.dart';
import '../services/plex_auth_service.dart';
import '../utils/app_logger.dart';

/// Provider for multi-server Plex connections
/// Manages multiple PlexClient instances and provides data aggregation
class MultiServerProvider extends ChangeNotifier {
  final MultiServerManager _serverManager;
  final DataAggregationService _aggregationService;
  StreamSubscription? _statusSubscription;

  MultiServerProvider(this._serverManager, this._aggregationService) {
    _statusSubscription = _serverManager.statusStream.listen((_) {
      notifyListeners();
    });
  }

  /// Get the multi-server manager
  MultiServerManager get serverManager => _serverManager;

  /// Get the data aggregation service
  DataAggregationService get aggregationService => _aggregationService;

  /// Get client for specific server
  PlexClient? getClientForServer(String serverId) {
    return _serverManager.getClient(serverId);
  }

  /// Get all online server IDs
  List<String> get onlineServerIds => _serverManager.onlineServerIds;

  /// Get all server IDs
  List<String> get serverIds => _serverManager.serverIds;

  /// Check if a server is online
  bool isServerOnline(String serverId) {
    return _serverManager.isServerOnline(serverId);
  }

  /// Get number of online servers
  int get onlineServerCount => _serverManager.onlineServerIds.length;

  /// Get number of total servers
  int get totalServerCount => _serverManager.serverIds.length;

  /// Check if any servers are connected
  bool get hasConnectedServers => onlineServerCount > 0;

  /// Clear all server connections
  void clearAllConnections() {
    _serverManager.disconnectAll();
    appLogger.d('MultiServerProvider: All connections cleared');
    notifyListeners();
  }

  /// Reconnect all servers after a profile switch
  /// Clears existing connections and connects to all provided servers
  Future<int> reconnectWithServers(List<PlexServer> servers, {String? clientIdentifier}) async {
    _serverManager.disconnectAll();
    appLogger.d('MultiServerProvider: Cleared connections, reconnecting to ${servers.length} servers');

    final connectedCount = await _serverManager.connectToAllServers(servers, clientIdentifier: clientIdentifier);

    appLogger.i('MultiServerProvider: Reconnected to $connectedCount/${servers.length} servers after profile switch');
    notifyListeners();
    return connectedCount;
  }

  /// Check server health for all connected servers
  Future<void> checkServerHealth() async {
    await _serverManager.checkServerHealth();
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _serverManager.dispose();
    super.dispose();
  }
}
