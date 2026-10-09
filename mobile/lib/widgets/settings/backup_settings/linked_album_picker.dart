import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/services/sync_linked_album.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/backup/backup_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';

/// Picks the device albums that are mirrored into a server album of the same name,
/// independently of which albums are backed up (fork-specific, strings are not localized).
class LinkedAlbumPicker extends ConsumerStatefulWidget {
  const LinkedAlbumPicker({super.key});

  @override
  ConsumerState<LinkedAlbumPicker> createState() => _LinkedAlbumPickerState();
}

class _LinkedAlbumPickerState extends ConsumerState<LinkedAlbumPicker> {
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    // Links are written straight to the DB, so pick up the latest state
    unawaited(ref.read(backupAlbumProvider.notifier).getAll());
  }

  Future<void> _toggle(LocalAlbum album, bool link) async {
    final user = ref.read(currentUserProvider);
    if (user == null) {
      return;
    }
    setState(() => _busy.add(album.id));
    final service = ref.read(syncLinkedAlbumServiceProvider);
    try {
      if (link) {
        // The same-name lookup only sees albums already synced to this device, so refresh
        // first; linking on a stale list would create a duplicate server album
        final synced = await ref.read(backgroundSyncProvider).syncRemote(enqueue: true);
        if (!synced) {
          _showMessage('サーバーと同期できなかったため、「${album.name}」を結び付けませんでした');
          return;
        }
        // Reuses a server album with the same name if there is one, otherwise creates it
        await service.manageLinkedAlbums([album], user.id);
      } else {
        await service.unlinkAlbum(album.id);
      }
      await ref.read(backupAlbumProvider.notifier).getAll();

      if (link) {
        final linked = ref.read(backupAlbumProvider).any((a) => a.id == album.id && a.linkedRemoteAlbumId != null);
        if (!linked) {
          _showMessage('「${album.name}」をサーバーのアルバムに結び付けられませんでした');
          return;
        }
        // Back-fill assets of this album that were uploaded before it was linked
        unawaited(ref.read(backgroundSyncProvider).syncLinkedAlbum());
      }
    } finally {
      if (mounted) {
        setState(() => _busy.remove(album.id));
      }
    }
  }

  void _showMessage(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(appConfigProvider.select((c) => c.backup.syncAlbums))) {
      return const SizedBox.shrink();
    }
    final albums = ref.watch(backupAlbumProvider);
    final linked = albums.where((a) => a.linkedRemoteAlbumId != null).toList();
    final ordered = [...linked, ...albums.where((a) => a.linkedRemoteAlbumId == null)];

    return Padding(
      padding: const EdgeInsets.only(left: 16),
      child: ExpansionTile(
        title: Text('同期するアルバム', style: context.textTheme.bodyLarge!.copyWith(fontWeight: FontWeight.w500)),
        subtitle: Text(
          linked.isEmpty ? 'なし' : linked.map((a) => a.name).join('、'),
          style: context.textTheme.bodyMedium,
        ),
        children: [
          ListTile(
            dense: true,
            title: Text(
              'ここで選んだアルバムの写真も、バックアップ対象（「最近の項目」など）に含まれている必要があります。'
              'サーバーに上がった写真だけが同名のアルバムに追加されます。',
              style: context.textTheme.bodySmall,
            ),
          ),
          for (final album in ordered)
            SwitchListTile.adaptive(
              title: Text(album.name),
              subtitle: Text('${album.assetCount} 枚'),
              value: album.linkedRemoteAlbumId != null,
              onChanged: _busy.contains(album.id) ? null : (value) => _toggle(album, value),
            ),
        ],
      ),
    );
  }
}
