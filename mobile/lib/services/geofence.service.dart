import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// iOS only: thin wrapper around the native region-monitoring trigger that wakes the
/// background worker when the device arrives at a stored location (see GeofenceTrigger.swift).
class GeofenceStatus {
  final bool enabled;
  final String authorization;
  final bool monitoringAvailable;
  final double? latitude;
  final double? longitude;
  final double? radius;

  const GeofenceStatus({
    required this.enabled,
    required this.authorization,
    required this.monitoringAvailable,
    this.latitude,
    this.longitude,
    this.radius,
  });

  bool get hasAlwaysPermission => authorization == 'always';

  factory GeofenceStatus.fromMap(Map<dynamic, dynamic> map) => GeofenceStatus(
    enabled: map['enabled'] as bool? ?? false,
    authorization: map['authorization'] as String? ?? 'unknown',
    monitoringAvailable: map['monitoringAvailable'] as bool? ?? false,
    latitude: (map['latitude'] as num?)?.toDouble(),
    longitude: (map['longitude'] as num?)?.toDouble(),
    radius: (map['radius'] as num?)?.toDouble(),
  );
}

class GeofenceService {
  static const _channel = MethodChannel('app.immich/geofence');

  const GeofenceService();

  Future<GeofenceStatus> getStatus() async {
    final map = await _channel.invokeMethod<Map<dynamic, dynamic>>('getStatus');
    return GeofenceStatus.fromMap(map ?? const {});
  }

  Future<GeofenceStatus> setHomeToCurrentLocation({double? radius}) async {
    final map = await _channel.invokeMethod<Map<dynamic, dynamic>>('setHomeToCurrentLocation', {'radius': ?radius});
    return GeofenceStatus.fromMap(map ?? const {});
  }

  Future<GeofenceStatus> disable() async {
    final map = await _channel.invokeMethod<Map<dynamic, dynamic>>('disable');
    return GeofenceStatus.fromMap(map ?? const {});
  }

  Future<void> triggerNow() => _channel.invokeMethod<void>('triggerNow');
}

final geofenceServiceProvider = Provider<GeofenceService>((ref) => const GeofenceService());
