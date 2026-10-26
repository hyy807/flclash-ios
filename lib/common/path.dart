import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';


/// Moves an existing iOS install's data into the shared container once, so a
/// profile imported before this change is still found by the tunnel.
@visibleForTesting
Future<Directory> migrateIOSDataDirectory({
  required Directory supportDirectory,
  required String appGroupPath,
}) async {
  final target = Directory(appGroupPath);
  await target.create(recursive: true);
  if (!await supportDirectory.exists() ||
      supportDirectory.absolute.path == target.absolute.path) {
    return target;
  }
  await for (final entity in supportDirectory.list(recursive: true)) {
    final targetPath = join(
      target.path,
      relative(entity.path, from: supportDirectory.path),
    );
    final name = basename(entity.path);
    if (name.startsWith('database.sqlite') || name == 'FlClash.lock') {
      continue;
    }
    if (entity is Directory) {
      await Directory(targetPath).create(recursive: true);
    } else if (entity is File && !await File(targetPath).exists()) {
      await File(targetPath).parent.create(recursive: true);
      await entity.copy(targetPath);
    }
  }
  return target;
}

class AppPath {
  static AppPath? _instance;
  late ResolveOnce<Directory> _dataDir;
  late ResolveOnce<Directory?> _downloadDir;
  late ResolveOnce<Directory> _tempDir;
  Completer<Directory> cacheDir = Completer();

  @visibleForTesting
  static Future<Directory> Function() supportDirectory =
      getApplicationSupportDirectory;

  @visibleForTesting
  static Future<Directory> Function() temporaryDirectory =
      getTemporaryDirectory;

  @visibleForTesting
  static Future<Directory> Function() cacheDirectory =
      getApplicationCacheDirectory;

  @visibleForTesting
  static Future<Directory?> Function() downloadDirectory =
      getDownloadsDirectory;

  AppPath._internal() {
    _bind();
  }

  @visibleForTesting
  Future<void> rebind() async {
    cacheDir = Completer();
    _bind();
    await Future.wait([_dataDir.value, _downloadDir.value, _tempDir.value]);
  }


  static const _appGroupChannel = MethodChannel('com.follow.clash/app_group');

  /// On iOS the core runs inside the packet tunnel extension, which cannot see
  /// the app's own sandbox. The profile, providers and geo data therefore have
  /// to live in the App Group container that both processes share.
  Future<Directory> _resolveDataDirectory() async {
    final support = await supportDirectory();
    if (!Platform.isIOS) {
      return support;
    }
    try {
      final groupPath =
          await _appGroupChannel.invokeMethod<String>('containerPath');
      if (groupPath == null || groupPath.isEmpty) {
        return support;
      }
      return await migrateIOSDataDirectory(
        supportDirectory: support,
        appGroupPath: groupPath,
      );
    } catch (_) {
      return support;
    }
  }

  void _bind() {
    _dataDir = ResolveOnce(_resolveDataDirectory);
    _downloadDir = ResolveOnce(downloadDirectory);
    _tempDir = ResolveOnce(temporaryDirectory);
    cacheDirectory().then(cacheDir.complete);
  }

  factory AppPath() {
    _instance ??= AppPath._internal();
    return _instance!;
  }

  String get executableExtension {
    return system.isWindows ? '.exe' : '';
  }

  String get executableDirPath {
    final currentExecutablePath = Platform.resolvedExecutable;
    return dirname(currentExecutablePath);
  }

  String get corePath {
    return join(executableDirPath, 'FlClashCore$executableExtension');
  }

  String get helperPath {
    return join(executableDirPath, '$appHelperService$executableExtension');
  }

  Future<String> get downloadDirPath async {
    final directory = await _downloadDir.value;
    return directory?.path ?? await homeDirPath;
  }

  Future<String> get homeDirPath async {
    final directory = await _dataDir.value;
    return directory.path;
  }

  /// Files only this process opens with locks stay in the private sandbox.
  /// iOS kills a suspended app (0xdead10cc) that holds a lock on a file in a
  /// shared App Group container, and SQLite and FlClash.lock both lock.
  Future<String> get privateDirPath async {
    if (!Platform.isIOS) {
      return homeDirPath;
    }
    final directory = await supportDirectory();
    await directory.create(recursive: true);
    return directory.path;
  }

  Future<String> get databasePath async {
    final mPrivateDirPath = await privateDirPath;
    return join(mPrivateDirPath, 'database.sqlite');
  }

  Future<String> get tempFilePath async {
    final mTempDir = await _tempDir.value;
    return join(mTempDir.path, 'temp$uniqueId');
  }

  Future<String> get lockFilePath async {
    final mPrivateDirPath = await privateDirPath;
    return join(mPrivateDirPath, 'FlClash.lock');
  }


  Future<String> get configFilePath async {
    final mHomeDirPath = await homeDirPath;
    return join(mHomeDirPath, 'config.yaml');
  }

  Future<String> get sharedPreferencesPath async {
    final directory = await _dataDir.value;
    return join(directory.path, 'shared_preferences.json');
  }

  Future<String> get profilesPath async {
    final directory = await _dataDir.value;
    return join(directory.path, profilesDirectoryName);
  }

  Future<String> getProfilePath(String fileName) async {
    return join(await profilesPath, '$fileName.yaml');
  }

  Future<String> get scriptsDirPath async {
    final path = await homeDirPath;
    return join(path, 'scripts');
  }

  Future<String> getScriptPath(String fileName) async {
    final path = await scriptsDirPath;
    return join(path, '$fileName.js');
  }

  Future<String> get providerCacheRootPath async {
    final directory = await homeDirPath;
    return join(directory, providersDirectoryName);
  }

  Future<String> getProviderCachePath(String fileName) async {
    return join(
      await providerCacheRootPath,
      rulesProviderDirectoryName,
      fileName,
    );
  }

  Future<String> getProvidersRootPath() async {
    final directory = await profilesPath;
    return join(directory, providersDirectoryName);
  }

  Future<String> getProviderDirPath(int profileId, String type) async {
    final directory = await getProvidersRootPath();
    return join(directory, profileId.toString(), type);
  }

  Future<void> ensureProviderDirs(int profileId) async {
    for (final type in const [
      proxiesProviderDirectoryName,
      rulesProviderDirectoryName,
    ]) {
      final directory = Directory(await getProviderDirPath(profileId, type));
      if (await directory.exists()) {
        continue;
      }
      await directory.create(recursive: true);
    }
  }

  Future<String> get tempPath async {
    final directory = await _tempDir.value;
    return directory.path;
  }
}

final appPath = AppPath();

String getBackupFileName() {
  return '${appName}_backup_${DateTime.now().show}.zip';
}

String get logFileName {
  return '${appName}_${DateTime.now().show}.log';
}
