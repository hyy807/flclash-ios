import 'dart:async';
import 'dart:io';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/pages/error.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rust_api/rust_api.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'application.dart';
import 'bootstrap.dart';
import 'common/app_data.dart';
import 'common/common.dart';
import 'common/preferences_store.dart';
import 'common/startup_trace.dart';
import 'common/window.dart';

void main(List<String> args) {
  runZonedGuarded(
    () async {
      StartupTrace.mark('main: enter');
      WidgetsFlutterBinding.ensureInitialized();
      StartupTrace.mark('main: binding ready');
      if (Platform.isWindows || Platform.isLinux) {
        SharedPreferencesStorePlatform.instance = AtomicFilePreferencesStore(
          appPath.sharedPreferencesPath,
        );
      }
      if (Platform.isLinux) {
        linkManager.seedInitialLink(args);
      }
      FlutterError.onError = (details) {
        StartupTrace.mark('flutterError', details.exception);
        Future.microtask(() {
          commonPrint.log(
            'exception: ${details.exception} stack: ${details.stack}',
            logLevel: LogLevel.warning,
          );
        });
      };
      try {
        StartupTrace.mark('main: RustLib.init');
        await RustLib.init();
        StartupTrace.mark('main: system.init');
        final version = await system.init();
        StartupTrace.mark('main: bootstrap.init', version);
        final container = await bootstrap.init(version);
        StartupTrace.mark('main: http overrides');
        await FlClashHttpOverrides.trustCoreRoots();
        HttpOverrides.global = FlClashHttpOverrides(container);
        request.attach(container.read);
        StartupTrace.mark('main: runApp');
        runApp(
          UncontrolledProviderScope(
            container: container,
            child: const Application(),
          ),
        );
      } catch (e, s) {
        traceError('main: init', e, s);
        runApp(
          InitErrorApp(
            error: e,
            stack: s,
            onClearData: clearAppData,
            onExit: _exitAfterInitFailure,
          ),
        );
        unawaited(window?.showInitFailure(onExit: _exitAfterInitFailure));
      }
    },
    (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
    },
  );
}

Future<void> _exitAfterInitFailure() async {
  await system.exit();
  window?.forceExit();
}
