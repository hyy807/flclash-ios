import 'dart:io';

/// A last-resort breadcrumb trail for launches that die before anything can be
/// shown on screen.
///
/// On iOS the app is started by SpringBoard: a crash inside the first frames
/// leaves no UI, no console and only an `.ips` whose Dart frames are an
/// unreadable AOT snapshot. Appending one line per startup phase into
/// `Documents/` (exposed to the Files app, see `UIFileSharingEnabled`) turns the
/// next report into a timeline — the last line written is the phase that did
/// not finish.
///
/// Synchronous on purpose: the process may be gone milliseconds later, so an
/// async write would be lost.
///
/// The path has to be found without plugins and without `HOME`: iOS does not
/// guarantee that the sandbox home is exported to the environment, so the first
/// candidate starts from the temp directory (the container root) instead.
class StartupTrace {
  StartupTrace._();

  static File? _file;
  static bool _resolved = false;

  static File? get _target {
    if (_resolved) {
      return _file;
    }
    _resolved = true;
    for (final candidate in _candidates()) {
      try {
        final documents = Directory(candidate);
        if (!documents.existsSync()) {
          continue;
        }
        _file = File('${documents.path}/flclash-startup.log');
        return _file;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  static Iterable<String> _candidates() sync* {
    try {
      // On iOS the temp directory is <container>/tmp, so its parent is the
      // container root and Documents is a sibling.
      yield '${Directory.systemTemp.parent.path}/Documents';
    } catch (_) {
      // Fall through to the next candidate.
    }
    try {
      yield '${Directory.current.path}/Documents';
    } catch (_) {
      // Fall through.
    }
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      yield '$home/Documents';
    }
  }

  static void mark(String phase, [Object? detail]) {
    final line =
        '${DateTime.now().toIso8601String()} [dart] $phase'
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
    StartupTrace.mark(
      '$phase stack',
      stack.toString().split('\n').take(12).join(' | '),
    );
  }
}
