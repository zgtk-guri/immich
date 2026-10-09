import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:mocktail/mocktail.dart';

import '../fixtures/asset.stub.dart';
import '../infrastructure/repository.mock.dart';
import '../mocks/asset_entity.mock.dart';
import '../repository.mocks.dart';
import '../service.mocks.dart';

// Fork: every finished upload is reported so it can go straight into its linked server albums.
void main() {
  late BackgroundUploadService sut;
  late MockUploadRepository mockUploadRepository;
  late MockStorageRepository mockStorageRepository;
  late MockLocalAssetRepository mockLocalAssetRepository;
  late MockAssetMediaRepository mockAssetMediaRepository;
  late List<(String, String)> uploaded;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async => 'test',
    );
    final db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: StoreRepository(db));
    await SettingsRepository.ensureInitialized(db);
    await Store.put(StoreKey.serverEndpoint, 'http://test-server.com');
    await Store.put(StoreKey.deviceId, 'test-device-id');
  });

  setUp(() {
    mockUploadRepository = MockUploadRepository();
    mockStorageRepository = MockStorageRepository();
    mockLocalAssetRepository = MockLocalAssetRepository();
    mockAssetMediaRepository = MockAssetMediaRepository();
    final mockAssetService = MockAssetService();
    when(() => mockAssetService.stackEditedUpload(any(), any(), any())).thenAnswer((_) async {});

    sut = BackgroundUploadService(
      mockUploadRepository,
      mockStorageRepository,
      mockLocalAssetRepository,
      MockBackupRepository(),
      mockAssetMediaRepository,
      mockAssetService,
    );
    uploaded = [];
    sut.onAssetUploaded = (localAssetId, remoteAssetId) async => uploaded.add((localAssetId, remoteAssetId));
  });

  tearDown(() => sut.dispose());

  void Function(TaskStatusUpdate) captureStatusCallback() =>
      verify(() => mockUploadRepository.onUploadStatus = captureAny()).captured.first;

  test('reports a plain photo once its upload completes', () async {
    final asset = LocalAssetStub.image1;
    final mockEntity = MockAssetEntity();
    final onStatus = captureStatusCallback();
    when(() => mockEntity.isLivePhoto).thenReturn(false);
    when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
    when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => File('/path/to/receipt.jpg'));
    when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'receipt.jpg');

    final task = await sut.getUploadTask(asset);
    onStatus(TaskStatusUpdate(task!, TaskStatus.running));
    onStatus(TaskStatusUpdate(task, TaskStatus.complete, null, '{"id": "remote"}'));
    await pumpEventQueue();

    expect(uploaded, [(asset.id, 'remote')]);
  });

  test('reports the still of a live photo, not its video', () async {
    final asset = LocalAssetStub.image1;
    final mockEntity = MockAssetEntity();
    final onStatus = captureStatusCallback();
    when(() => mockEntity.isLivePhoto).thenReturn(true);
    when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
    when(() => mockStorageRepository.getMotionFileForAsset(asset)).thenAnswer((_) async => File('/path/to/motion.mov'));
    when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => File('/path/to/still.heic'));
    when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'live.heic');
    when(() => mockLocalAssetRepository.getById(asset.id)).thenAnswer((_) async => null);

    final video = await sut.getUploadTask(asset);
    final still = await sut.getLivePhotoUploadTask(asset, 'video');
    onStatus(TaskStatusUpdate(video!, TaskStatus.complete, null, '{"id": "video"}'));
    onStatus(TaskStatusUpdate(still!, TaskStatus.complete, null, '{"id": "still"}'));
    await pumpEventQueue();

    expect(uploaded, [(asset.id, 'still')]);
  });

  test('ignores a failed upload', () async {
    final asset = LocalAssetStub.image1;
    final mockEntity = MockAssetEntity();
    final onStatus = captureStatusCallback();
    when(() => mockEntity.isLivePhoto).thenReturn(false);
    when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
    when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => File('/path/to/receipt.jpg'));
    when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'receipt.jpg');

    final task = await sut.getUploadTask(asset);
    onStatus(TaskStatusUpdate(task!, TaskStatus.failed));
    await pumpEventQueue();

    expect(uploaded, isEmpty);
  });
}
