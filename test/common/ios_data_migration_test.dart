import 'dart:io';

import 'package:fl_clash/common/path.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('iOS migration shares core files but not database or lifetime lock', () async {
    final root = await Directory.systemTemp.createTemp('ios-migration-');
    addTearDown(() => root.delete(recursive: true));
    final support = await Directory(p.join(root.path, 'private')).create();
    final group = Directory(p.join(root.path, 'group'));
    for (final name in [
      'config.yaml', 'database.sqlite', 'database.sqlite-wal',
      'database.sqlite-shm', 'FlClash.lock', 'profiles/one.yaml',
    ]) {
      final file = File(p.join(support.path, name));
      await file.parent.create(recursive: true);
      await file.writeAsString(name);
    }
    await migrateIOSDataDirectory(
      supportDirectory: support, appGroupPath: group.path,
    );
    expect(await File(p.join(group.path, 'config.yaml')).readAsString(), 'config.yaml');
    expect(await File(p.join(group.path, 'profiles/one.yaml')).exists(), isTrue);
    for (final name in ['database.sqlite', 'database.sqlite-wal',
      'database.sqlite-shm', 'FlClash.lock']) {
      expect(await File(p.join(group.path, name)).exists(), isFalse, reason: name);
      expect(await File(p.join(support.path, name)).exists(), isTrue);
    }
    await File(p.join(group.path, 'config.yaml')).writeAsString('updated');
    await migrateIOSDataDirectory(
      supportDirectory: support, appGroupPath: group.path,
    );
    expect(await File(p.join(group.path, 'config.yaml')).readAsString(), 'updated');
  });
}
