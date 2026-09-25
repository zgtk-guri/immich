import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/services/geofence.service.dart';
import 'package:immich_mobile/widgets/settings/setting_list_tile.dart';

/// iOS only. Lets the user store the current position as "home" so that arriving there
/// wakes the background worker (fork-specific feature, strings are not localized).
class GeofenceSettings extends ConsumerStatefulWidget {
  const GeofenceSettings({super.key});

  @override
  ConsumerState<GeofenceSettings> createState() => _GeofenceSettingsState();
}

class _GeofenceSettingsState extends ConsumerState<GeofenceSettings> {
  GeofenceStatus? _status;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      final status = await ref.read(geofenceServiceProvider).getStatus();
      if (mounted) {
        setState(() => _status = status);
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() => _error = e.message);
      }
    }
  }

  Future<void> _run(Future<GeofenceStatus> Function(GeofenceService s) action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = await action(ref.read(geofenceServiceProvider));
      if (mounted) {
        setState(() => _status = status);
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() => _error = e.message ?? e.code);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  String _authorizationLabel(String authorization) => switch (authorization) {
    'always' => '常に許可',
    'whenInUse' => '使用中のみ許可（「常に」が必要です）',
    'denied' => '拒否（設定アプリで変更してください）',
    'restricted' => '制限あり',
    'notDetermined' => '未設定',
    _ => authorization,
  };

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final subtitle = switch (status) {
      null => _error ?? '読み込み中…',
      GeofenceStatus(enabled: true, latitude: final lat?, longitude: final lon?, radius: final r?) =>
        '設定済み: ${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}（半径 ${r.round()} m）\n'
            '位置情報: ${_authorizationLabel(status.authorization)}',
      GeofenceStatus(monitoringAvailable: false) => 'この端末では利用できません',
      _ =>
        '自宅などに着いたときに、アプリを開かなくてもバックアップを開始します。\n'
            '位置情報: ${_authorizationLabel(status.authorization)}',
    };

    return Column(
      children: [
        SettingListTile(
          title: '到着時にバックアップ（実験的）',
          subtitle: subtitle,
          trailing: Switch(
            value: status?.enabled ?? false,
            onChanged: _busy || status == null || !status.monitoringAvailable
                ? null
                : (value) => _run((s) => value ? s.setHomeToCurrentLocation() : s.disable()),
          ),
        ),
        if (status?.enabled ?? false)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: _busy ? null : () => _run((s) => s.setHomeToCurrentLocation()),
                  icon: const Icon(Icons.my_location),
                  label: const Text('現在地を自宅にし直す'),
                ),
                TextButton.icon(
                  onPressed: _busy
                      ? null
                      : () async {
                          await ref.read(geofenceServiceProvider).triggerNow();
                          if (context.mounted) {
                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(const SnackBar(content: Text('5 秒後にバックグラウンドワーカーを起動します。今すぐホームに戻ってください')));
                          }
                        },
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('テスト実行'),
                ),
              ],
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(_error!, style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.error)),
            ),
          ),
      ],
    );
  }
}
