import 'package:flutter_test/flutter_test.dart';
import 'package:querypic/screens/folder_picker_screen.dart';

/// Folder-picker selection math (host-runnable, no platform channels).
void main() {
  group('resolveFolderSelection', () {
    test('blank aggregate never counted nor shown', () {
      final out = resolveFolderSelection(
        saved: const [],
        albums: const ['', 'Camera', 'Screenshots'],
        firstRun: true,
      );
      expect(out.visible, ['Camera', 'Screenshots']);
      expect(out.selected, {'Camera', 'Screenshots'});
      // The device bug: 34 selected of 33 visible. Never again.
      expect(out.selected.length, out.visible.length);
      expect(out.selected.difference(out.visible.toSet()), isEmpty);
    });

    test('keeps prior selection, drops vanished albums', () {
      final out = resolveFolderSelection(
        saved: const ['Camera', 'GoneAlbum'],
        albums: const ['Camera', 'Screenshots'],
        firstRun: false,
      );
      expect(out.selected, {'Camera'});
    });

    test('non-first-run with empty saved selects nothing', () {
      final out = resolveFolderSelection(
        saved: const [],
        albums: const ['Camera'],
        firstRun: false,
      );
      expect(out.selected, isEmpty);
      expect(out.visible, ['Camera']);
    });

    test('master checkbox math stays consistent', () {
      final out = resolveFolderSelection(
        saved: const ['a', 'b', 'c'],
        albums: const ['', 'a', 'b', 'c'],
        firstRun: true,
      );
      // All visible selected -> master box checks itself.
      expect(out.selected.length, out.visible.length);
    });
  });
}
