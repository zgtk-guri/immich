import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/services/sync_linked_album.service.dart';
import 'package:mocktail/mocktail.dart';

import '../../infrastructure/repository.mock.dart';
import '../../service.mocks.dart';

// Fork: only device albums the user linked one by one are mirrored into server albums,
// and a finished upload goes straight into its linked server albums.
void main() {
  late MockLocalAlbumRepository localAlbumRepository;
  late MockRemoteAlbumRepository remoteAlbumRepository;
  late MockAlbumApiRepository albumApiRepository;
  late SyncLinkedAlbumService sut;

  final receipts = LocalAlbum(
    id: 'local-receipts',
    name: 'レシート',
    updatedAt: DateTime(2026),
    linkedRemoteAlbumId: 'remote-receipts',
  );
  final travel = LocalAlbum(
    id: 'local-travel',
    name: '旅行',
    updatedAt: DateTime(2026),
    linkedRemoteAlbumId: 'remote-travel',
  );
  final remoteReceipts = RemoteAlbum(
    id: 'remote-receipts',
    name: 'レシート',
    ownerId: 'user-1',
    description: '',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    isActivityEnabled: false,
    order: AlbumAssetOrder.desc,
    assetCount: 31,
    ownerName: 'user',
    isShared: false,
  );

  setUp(() {
    localAlbumRepository = MockLocalAlbumRepository();
    remoteAlbumRepository = MockRemoteAlbumRepository();
    albumApiRepository = MockAlbumApiRepository();
    sut = SyncLinkedAlbumService(localAlbumRepository, remoteAlbumRepository, albumApiRepository, MockStoreService());

    when(() => albumApiRepository.addAssets(any(), any(), abortTrigger: any(named: 'abortTrigger'))).thenAnswer(
      (invocation) async =>
          (added: (invocation.positionalArguments[1] as Iterable<String>).toList(), failed: <String>[]),
    );
    when(() => remoteAlbumRepository.addAssets(any(), any())).thenAnswer((_) async => 0);
  });

  group('syncLinkedAlbums', () {
    test('mirrors linked albums only, not every backup album', () async {
      when(() => localAlbumRepository.getLinkedAlbums()).thenAnswer((_) async => [receipts]);
      when(() => remoteAlbumRepository.get('remote-receipts')).thenAnswer((_) async => remoteReceipts);
      when(
        () => remoteAlbumRepository.getLinkedAssetIds('user-1', 'local-receipts', 'remote-receipts'),
      ).thenAnswer((_) async => ['asset-1', 'asset-2']);

      await sut.syncLinkedAlbums('user-1');

      verifyNever(() => localAlbumRepository.getBackupAlbums());
      verify(() => albumApiRepository.addAssets('remote-receipts', ['asset-1', 'asset-2'])).called(1);
      verify(() => remoteAlbumRepository.addAssets('remote-receipts', ['asset-1', 'asset-2'])).called(1);
    });
  });

  group('addUploadedAsset', () {
    test('adds the uploaded asset to every linked album it is in', () async {
      when(() => localAlbumRepository.getLinkedAlbumsForAsset('local-1')).thenAnswer((_) async => [receipts, travel]);

      await sut.addUploadedAsset('local-1', 'remote-1');

      verify(() => albumApiRepository.addAssets('remote-receipts', ['remote-1'])).called(1);
      verify(() => albumApiRepository.addAssets('remote-travel', ['remote-1'])).called(1);
    });

    test('does nothing when the asset is in no linked album', () async {
      when(() => localAlbumRepository.getLinkedAlbumsForAsset('local-1')).thenAnswer((_) async => []);

      await sut.addUploadedAsset('local-1', 'remote-1');

      verifyNever(() => albumApiRepository.addAssets(any(), any()));
    });

    test('keeps going when adding to one album fails', () async {
      when(() => localAlbumRepository.getLinkedAlbumsForAsset('local-1')).thenAnswer((_) async => [receipts, travel]);
      when(() => albumApiRepository.addAssets('remote-receipts', any())).thenThrow(Exception('offline'));

      await sut.addUploadedAsset('local-1', 'remote-1');

      verify(() => albumApiRepository.addAssets('remote-travel', ['remote-1'])).called(1);
    });
  });
}
