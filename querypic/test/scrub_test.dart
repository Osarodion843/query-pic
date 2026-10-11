import 'package:flutter_test/flutter_test.dart';
import 'package:querypic/services/scrub.dart';

/// Pure-logic tests for the Phase 8 PII scrubber (host-runnable).
/// Includes an exfiltration attempt: a PII-laden fake crash payload must
/// come out containing only allowlisted keys with redacted values.
void main() {
  group('Scrub.text', () {
    test('redacts file paths and URIs', () {
      expect(
        Scrub.text('open /storage/emulated/0/DCIM/beach.jpg failed'),
        contains('<file>'),
      );
      expect(
        Scrub.text('open /storage/emulated/0/DCIM/beach.jpg failed'),
        isNot(contains('beach.jpg')),
      );
      expect(
        Scrub.text('playing content://media/video/42 now'),
        contains('<file>'),
      );
    });

    test('redacts GPS pairs and long tokens', () {
      expect(
        Scrub.text('fix at 12.3456, -65.4321 taken'),
        contains('<gps>'),
      );
      expect(
        Scrub.text('key abcdefghijklmnopqrstuvwxyz0123456789 bad'),
        contains('<token>'),
      );
    });

    test('leaves plain words alone', () {
      expect(Scrub.text('null pointer in fusion'), 'null pointer in fusion');
    });
  });

  group('Scrub.payload', () {
    test('allowlist keeps stack/os/model, drops everything else', () {
      final out = Scrub.payload({
        'stack': '#0 fusion (/a/b/query_engine.dart:12)',
        'os': 'Android 14',
        'model': 'itel S666LN',
        'query': 'happy birthday',
        'folder': '/storage/photos',
        'vectors': 'AAECAwQFBgcICQoLDA0ODxAREhM=',
      });
      expect(out.keys.toSet(), {'stack', 'os', 'model'});
      expect(out['stack'], isNot(contains('query_engine.dart')));
      expect(out['os'], 'Android 14');
    });

    test('exfiltration attempt via crash path is redacted', () {
      // Attacker-controlled strings smuggled into an exception message.
      final evil = StateError(
        'query="my secret doc" path=/sdcard/private/img.jpg '
        'gps=12.345678,-65.432109 token=supersecretkeymaterial0123456789',
      );
      final out = Scrub.payload({'stack': '$evil', 'query': 'x'});
      expect(out, isNot(contains('secret doc')));
      expect(out.toString(), isNot(contains('/sdcard/private')));
      expect(out.toString(), isNot(contains('12.345678')));
      expect(out.containsKey('query'), isFalse);
    });
  });
}
