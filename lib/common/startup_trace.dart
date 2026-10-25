import 'dart:io';

/// A last-resort breadcrumb trail for launches that die before anything can be
/// shown on screen.
///
/// On iOS the app is started by SpringBoard and a crash inside the first frames
/// leaves no UI, no console and only an `.ips` whose stacks are all system
/// frames. Appending one line per startup phase into `Documents/` (exposed to
/// the Files app, see `UIFileSharingEnabled`) turns the next report into a
/// timeline: the last line written is the phase that did not finish.
///
/// Synchronous on purpose: the process may be gone a few milliseconds later,
/// so an async write would be lost.
class StartupTrace {
  StartupTrace._();

  static File? _file;
  static bool _resolved = false;

  static File? get _target {
    if (_resolved) {
      return _file;
    }
    _resolved = true;
    try {
      final home = Platform.environment['HOME'];
      if (home == null || home.isEmpty) {
        return null;
      }
      final documents = Directory('$home/Documents');
      if (!documents.existsSync()) {
        return null;
      }
      _file = File('${documents.path}/flclash-startup.log');
    } catch (_) {
      _file = null;
    }
    return _file;
  }

  static void mark(String phase, [Object? detail]) {
    final line =
        '${DateTime.now().toIso8601String()} $phase'
        '${detail == null ? '' : ' :: $detail'}';
    try {
      _target?.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Tracing must never be the reason a launch fails.
    }
    // Also goes to os_log so `Console.app` shows it when a Mac is attached.
    stdout.writeln('[FlClash] $line');
  }
}

/// Convenience for the common "phase failed" shape.
void traceError(String phase, Object error, [StackTrace? stack]) {
  StartupTrace.mark('$phase FAILED', error);
  if (stack != null) {
    StartupTrace.mark('$phase stack', stack.toString().split('\n').take(12).join(' | '));
  }
}
