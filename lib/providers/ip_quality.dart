import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/ip_quality.dart';
import 'package:fl_clash/common/startup_trace.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'core.dart';

part 'generated/ip_quality.g.dart';

Duration? _noRetry(int retryCount, Object error) => null;

@Riverpod(keepAlive: true)
Duration ipQualityFailureCooldown(Ref ref) => const Duration(minutes: 5);

@Riverpod(retry: _noRetry)
Future<IpQuality> ipQuality(Ref ref, String ip) async {
  final cancelToken = CancelToken();
  ref.onDispose(cancelToken.cancel);
  try {
    final quality = await lookupIpQuality(
      request.dio,
      ip,
      cancelToken: cancelToken,
      fetch: system.isIOS ? ref.read(coreHandlerProvider).probe : null,
    );
    if (!ref.mounted) {
      throw DioException.requestCancelled(
        requestOptions: RequestOptions(path: ''),
        reason: null,
      );
    }
    ref.keepAlive();
    return quality;
  } on IpQualityLookupException catch (error) {
    if (!ref.mounted) {
      rethrow;
    }
    final failures = error.failures
        .map((f) {
          final detail = error.details[f.source];
          return '${f.source.label} ${f.status.name}'
              '${detail == null ? '' : ' (${detail.summary})'}';
        })
        .join(', ');
    commonPrint.log(
      'ip quality lookup failed: $failures',
      logLevel: LogLevel.warning,
    );
    StartupTrace.mark('ip quality lookup failed', failures);
    final link = ref.keepAlive();
    final timer = Timer(ref.read(ipQualityFailureCooldownProvider), link.close);
    ref.onDispose(timer.cancel);
    rethrow;
  }
}
