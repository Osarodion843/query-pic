import 'package:flutter_test/flutter_test.dart';
import 'package:querypic/services/media_source.dart';

/// URI contract between indexer, results grid and native handoff.
void main() {
  group('photo asset URIs', () {
    test('round-trips an asset id', () {
      const id = '12345';
      expect(photoAssetIdFromUri(photoAssetUri(id)), id);
    });

    test('rejects synthetic and legacy URIs', () {
      expect(photoAssetIdFromUri('demo://receipt_home_depot.jpg'), isNull);
      expect(photoAssetIdFromUri('scale://photo_00001.jpg'), isNull);
      expect(photoAssetIdFromUri('Camera Roll'), isNull);
      expect(photoAssetIdFromUri('photoid://'), isNull);
      expect(photoAssetIdFromUri(''), isNull);
    });
  });
}
