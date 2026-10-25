import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (input.userDefines['build_assets'] == false) {
      stdout.writeln('Skipping the Rust build: user-define build_assets=false');
      return;
    }
    await FlutterRustBridgeNativeAssetsBuilder(
      cratePath: 'rust',
      extraCargoEnvironmentVariables: _bindgenEnvironment(input),
    ).run(input: input, output: output);
  });
}

// rquickjs runs bindgen on Android, which must load the NDK's libclang; Linux
// NDKs before r26 keep it under lib64, later ones and every macOS NDK under lib.
Map<String, String> _bindgenEnvironment(BuildInput input) {
  final targetOS = input.config.code.targetOS;
  if (!input.config.buildCodeAssets) {
    return const {};
  }
  if (targetOS == OS.iOS) {
    // QuickJS is compiled against the installed Xcode SDK; without an explicit
    // deployment target the link runs at iOS 10.0 where ___chkstk_darwin is
    // absent, so the final rust_api link fails with undefined symbols.
    return const {
      'IPHONEOS_DEPLOYMENT_TARGET': '15.0',
      'RUSTFLAGS': '-C link-arg=-miphoneos-version-min=15.0',
    };
  }
  if (targetOS != OS.android) {
    return const {};
  }
  final compiler = input.config.code.cCompiler?.compiler;
  if (compiler == null) {
    return const {};
  }
  final llvmRoot = File.fromUri(compiler).parent.parent;
  for (final name in const ['lib', 'lib64']) {
    final directory = Directory(
      '${llvmRoot.path}${Platform.pathSeparator}$name',
    );
    if (directory.existsSync() && directory.listSync().any(_isLibclang)) {
      return {'LIBCLANG_PATH': directory.path};
    }
  }
  // NDK r27 may omit the shared libclang; bindgen can use the host LLVM
  // library while the Android compiler/sysroot still select target headers.
  for (final path in [
    if (Platform.environment['LIBCLANG_PATH'] case final String path) path,
    '/usr/lib/llvm-18/lib',
    '/usr/lib/llvm-17/lib',
    '/usr/lib/llvm-14/lib',
  ]) {
    final directory = Directory(path);
    if (directory.existsSync() && directory.listSync().any(_isLibclang)) {
      return {'LIBCLANG_PATH': directory.path};
    }
  }
  throw StateError(
    'No libclang under ${llvmRoot.path} (lib or lib64); the toolchain '
    'Flutter passed cannot run bindgen for rquickjs',
  );
}

bool _isLibclang(FileSystemEntity entity) {
  return entity.path.split(Platform.pathSeparator).last.startsWith('libclang.');
}
