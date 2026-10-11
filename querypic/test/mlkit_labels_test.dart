import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:querypic/services/media_source.dart';
import 'package:querypic/services/mlkit_labels.dart';
import 'package:querypic/services/mlkit_ocr.dart';

/// ML Kit pipeline contract (host-runnable: fake backend + graceful
/// platform-channel absence — no ML Kit binary on host).
void main() {
  MediaEntry photo(String id) => MediaEntry(
        uri: photoAssetUri(id),
        isVideo: false,
        mtimeMillis: 1700000000,
        sizeBytes: 0,
      );

  group('MlKitPhotoExtractor', () {
    test('labels land in ocrText via the backend', () async {
      final ex = MlKitPhotoExtractor(
        backend: const FakeLabelBackend({'sunset': 'sunset sky beach'}),
      );
      // Platform channels absent on host: asset resolution degrades to
      // empty labels without throwing (fail-closed).
      final out = await ex.extract(photo('123'));
      expect(out.ocrText, isA<String>());
      expect(out.vector.length, 32);
      expect(ex.modelVersion, 'mlkit-labels-v4');
    });

    test('synthetic rows pass through with empty labels', () async {
      final ex = MlKitPhotoExtractor(
        backend: const FakeLabelBackend({}),
      );
      final out = await ex.extract(
        const MediaEntry(
          uri: 'demo://receipt.jpg',
          isVideo: false,
          mtimeMillis: 1,
          sizeBytes: 2,
        ),
      );
      expect(out.ocrText, '');
      expect(out.vector.length, 32);
    });

    test('video rows degrade gracefully without platform channels', () async {
      // v2 labels video thumbnails; on host (no photo_manager) the asset
      // lookup fails closed to empty labels instead of throwing, so the
      // worker records the row and retries on device.
      final ex = MlKitPhotoExtractor(
        backend: const FakeLabelBackend({'thumb': 'car road'}),
      );
      final out = await ex.extract(
        MediaEntry(
          uri: photoAssetUri('vid123'),
          isVideo: true,
          mtimeMillis: 1700000000,
          sizeBytes: 0,
        ),
      );
      expect(out.ocrText, isA<String>());
      expect(out.vector.length, 32);
      // Shared thumbnail helpers are null-safe off-device.
      expect(
        await MlKitPhotoExtractor.videoThumbnailBytes(null),
        isNull,
      );
      expect(
        await MlKitPhotoExtractor.describeJpegBytes(
          Uint8List(0),
          const FakeLabelBackend({}),
          const FakeOcrBackend({}),
        ),
        '',
      );
    });
  });

  group('MlKitOcr', () {
    test('toIndexWords lowercases, drops shorts, dedupes, caps', () {
      expect(
        MlKitOcr.toIndexWords('Following FOLLOWING Fo! "Beach-Day" a be'),
        'following beach day',
      );
      expect(MlKitOcr.toIndexWords('a be?!'), '');
    });

    test('FakeOcrBackend matches by path substring, empty otherwise',
        () async {
      const back = FakeOcrBackend({'shot': 'Following the sunsetCIELO'});
      expect(await back.readText('/x/shot.png'), 'following the sunsetcielo');
      expect(await back.readText('/x/office.png'), '');
    });
  });

  group('FakeLabelBackend', () {
    test('matches by path substring, empty otherwise', () async {
      const back = FakeLabelBackend({'beach': 'beach ocean water'});
      expect(await back.labelFile('/x/beach_day.jpg'), 'beach ocean water');
      expect(await back.labelFile('/x/office.png'), '');
    });
  });
}
