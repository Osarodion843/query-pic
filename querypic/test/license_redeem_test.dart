import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:querypic/services/device_store.dart';
import 'package:querypic/services/license_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Single-use redemption contracts (host-runnable): a local HttpServer
/// stands in for server/api/redeem.js with scripted statuses.
void main() {
  late HttpServer server;
  late String base;
  final bodies = <Map<String, Object?>>[];

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final body = json.decode(await utf8.decodeStream(request))
          as Map<String, Object?>;
      bodies.add(body);
      final key = body['key'] as String?;
      request.response.headers.contentType = ContentType.json;
      if (key == 'QP-PRO-GOOD-KEY1') {
        request.response.statusCode = 200;
        request.response.write('{"ok":true}');
      } else if (key == 'QP-PRO-USED-KEY1') {
        request.response.statusCode = 410;
        request.response.write('{"ok":false,"error":"used"}');
      } else {
        request.response.statusCode = 404;
        request.response.write('{"ok":false,"error":"unknown"}');
      }
      await request.response.close();
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  group('LicenseStore.redeem', () {
    test('bad format fails before any network', () async {
      final out = await LicenseStore.redeem('nope', baseUrl: base);
      expect(out.ok, isFalse);
      expect(out.message, contains('QP-PRO-XXXX-XXXX'));
    });

    test('empty base URL is the dev-only offline accept', () async {
      final out = await LicenseStore.redeem(
        'QP-PRO-AB12-CD34',
        baseUrl: '',
      );
      expect(out.ok, isTrue);
    });

    test('200 unlocks', () async {
      final out = await LicenseStore.redeem(
        'QP-PRO-GOOD-KEY1',
        baseUrl: base,
      );
      expect(out.ok, isTrue);
    });

    test('redeem binds device AND account (single-use scope)', () async {
      bodies.clear();
      await LicenseStore.redeem('QP-PRO-GOOD-KEY1', baseUrl: base);
      expect(bodies, isNotEmpty);
      final last = bodies.last;
      expect(last['deviceId'], isA<String>());
      expect((last['deviceId'] as String).isNotEmpty, isTrue);
      // Account key present (empty pre-accounts, profile id after).
      expect(last.containsKey('account'), isTrue);
    });

    test('404 reports unknown key', () async {
      final out = await LicenseStore.redeem(
        'QP-PRO-NOPE-NOPE',
        baseUrl: base,
      );
      expect(out.ok, isFalse);
      expect(out.message, contains('Unknown key'));
    });

    test('410 reports already-used with support route', () async {
      final out = await LicenseStore.redeem(
        'QP-PRO-USED-KEY1',
        baseUrl: base,
      );
      expect(out.ok, isFalse);
      expect(out.message, contains('already used'));
    });

    test('unreachable server fails friendly, never throws', () async {
      final out = await LicenseStore.redeem(
        'QP-PRO-AB12-CD34',
        baseUrl: 'http://127.0.0.1:1',
      );
      expect(out.ok, isFalse);
      expect(out.message, contains('verification server'));
    });
  });

  group('DeviceStore', () {
    test('install id is stable across calls', () async {
      expect(await DeviceStore.deviceId(), await DeviceStore.deviceId());
      expect((await DeviceStore.deviceId()).length, greaterThan(20));
    });
  });
}
