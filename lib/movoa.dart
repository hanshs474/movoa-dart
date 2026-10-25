/// Official Dart SDK for Movoa (https://movoa.ai), the AI video generator
/// with sound.
///
/// ```dart
/// final movoa = Movoa(); // reads MOVOA_API_KEY
/// final clip = await movoa.generateVideo('a lighthouse in a storm, thunder');
/// ```
library;

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;

/// The service this package talks to.
const movoaBaseUrl = 'https://movoa.ai';

/// Where an API key is created.
const movoaKeysUrl = 'https://movoa.ai/settings/apikeys';

/// The default model.
const movoaDefaultModel = 'minimax-h3';

/// Package version, sent in the User-Agent.
const movoaVersion = '0.1.0';

const _keyHint = 'Create a key at $movoaKeysUrl and set MOVOA_API_KEY.';

/// Every error this package throws on purpose. Catch a subclass to decide
/// what to do next, or this one for anything else (network, 5xx, non-JSON).
class MovoaException implements Exception {
  final String message;

  /// The HTTP status the service answered with, or null without a response.
  final int? statusCode;

  /// The service's `data.reason`, e.g. `insufficient_credits`.
  final String? reason;

  /// The run this error is about (failed and timed-out runs).
  final String? taskId;

  const MovoaException(this.message,
      {this.statusCode, this.reason, this.taskId});

  @override
  String toString() => '$runtimeType: $message';
}

/// No API key, or the key is wrong or deleted.
class MovoaAuthException extends MovoaException {
  const MovoaAuthException(super.message, {super.statusCode});
}

/// The content filter refused the prompt, or the account is cooling down
/// after a refusal. Reword rather than retry.
class MovoaRejectedException extends MovoaException {
  const MovoaRejectedException(super.message, {super.statusCode});
}

/// Not enough credits left on the account for this run.
class MovoaQuotaException extends MovoaException {
  const MovoaQuotaException(super.message, {super.statusCode})
      : super(reason: 'insufficient_credits');
}

/// This model or quality needs a plan, or the account has not bought
/// credits yet.
class MovoaPlanException extends MovoaException {
  const MovoaPlanException(super.message, {super.statusCode})
      : super(reason: 'plan_required');
}

/// Another generation on this account is still running.
class MovoaBusyException extends MovoaException {
  const MovoaBusyException(super.message, {super.statusCode})
      : super(reason: 'concurrency');
}

/// The run was accepted and then failed or was canceled.
class MovoaGenerationException extends MovoaException {
  /// The service's `errorMessage` for the run.
  final String? errorMessage;

  /// The service's `failureKind` for the run.
  final String? failureKind;

  const MovoaGenerationException(super.message,
      {required String super.taskId, this.errorMessage, this.failureKind});
}

/// The wait ran out; the run may still finish. Look it up later with
/// [Movoa.status] and [taskId].
class MovoaTimeoutException extends MovoaException {
  const MovoaTimeoutException(super.message, {required String super.taskId});
}

/// Map one answer of movoa.ai to its `data`, or throw the matching exception.
///
/// movoa.ai answers almost every refusal as HTTP 200 with a non-zero `code`
/// and a `data.reason`, so the status code alone reads a refusal as success.
Object? checkResponse(int status, Object? body) {
  if (status == 401) {
    final m = body is Map ? body['message'] : null;
    throw MovoaAuthException(m is String ? m : 'Invalid API key. $_keyHint',
        statusCode: 401);
  }
  if (body is! Map) {
    throw MovoaException('movoa.ai returned a non-JSON response (HTTP $status)',
        statusCode: status);
  }
  final code = body['code'];
  if (code == 0) return body['data'];
  final message = body['message'] is String
      ? body['message'] as String
      : 'request failed (HTTP $status)';
  if (code == -2 || code == -3) {
    throw MovoaRejectedException(message, statusCode: status);
  }
  final data = body['data'];
  final reason = data is Map ? data['reason'] as String? : null;
  switch (reason) {
    case 'insufficient_credits':
      throw MovoaQuotaException(message, statusCode: status);
    case 'plan_required':
      throw MovoaPlanException(message, statusCode: status);
    case 'concurrency':
      throw MovoaBusyException(message, statusCode: status);
  }
  if (message.toLowerCase().contains('no auth')) {
    throw MovoaAuthException('$message. $_keyHint', statusCode: status);
  }
  throw MovoaException(message, statusCode: status, reason: reason);
}

/// One run as `/api/ai/query` reports it.
class MovoaStatus {
  final String id;

  /// `pending`, `processing`, `success`, `failed` or `canceled`.
  final String status;

  /// The finished clips once [status] is `success`.
  final List<String> videos;
  final String? errorMessage;
  final String? failureKind;

  /// True while the run waits in the queue.
  final bool queued;

  /// Estimated seconds left in the queue.
  final int? queueEta;

  /// The whole `data` object as the service sent it.
  final Map<String, dynamic> raw;

  MovoaStatus(this.raw)
      : id = '${raw['id'] ?? ''}',
        status = '${raw['status'] ?? ''}',
        videos = [for (final v in (raw['videos'] as List?) ?? const []) '$v'],
        errorMessage = raw['errorMessage'] as String?,
        failureKind = raw['failureKind'] as String?,
        queued = raw['queued'] == true,
        queueEta = (raw['queueEta'] as num?)?.toInt();

  /// The first finished clip, or null.
  String? get videoUrl => videos.isEmpty ? null : videos.first;
  bool get isSuccess => status == 'success';
  bool get isFailed => status == 'failed' || status == 'canceled';
}

/// A client bound to one API key.
class Movoa {
  final String apiKey;
  final String baseUrl;
  final http.Client _client;

  /// Time between status checks while waiting.
  Duration pollEvery;

  /// Total wait for one run; a queued run can take a while.
  Duration timeout;

  /// A missing key reads MOVOA_API_KEY; a missing [baseUrl] reads
  /// MOVOA_BASE_URL, then falls back to https://movoa.ai.
  Movoa(
      {String? apiKey,
      String? baseUrl,
      http.Client? client,
      this.pollEvery = const Duration(seconds: 10),
      this.timeout = const Duration(minutes: 30)})
      : apiKey = (apiKey ?? _env('MOVOA_API_KEY') ?? '').trim(),
        baseUrl = (baseUrl ?? _env('MOVOA_BASE_URL') ?? movoaBaseUrl)
            .replaceAll(RegExp(r'/+$'), ''),
        _client = client ?? http.Client();

  static String? _env(String name) {
    try {
      final v = Platform.environment[name];
      return v == null || v.trim().isEmpty ? null : v;
    } catch (_) {
      return null; // web: no environment
    }
  }

  /// Start a run and return its id without waiting.
  ///
  /// [imageUrl] (a public https image) makes it photo to video, with the
  /// image as the first frame. [options] go to the model as-is, e.g.
  /// `{'duration': 8, 'resolution': '768p', 'aspect_ratio': '9:16'}`.
  Future<String> submit(String prompt,
      {String model = movoaDefaultModel,
      String? imageUrl,
      Map<String, Object?> options = const {}}) async {
    if (prompt.trim().isEmpty) {
      throw ArgumentError.value(prompt, 'prompt', 'is required');
    }
    final i2v = imageUrl != null && imageUrl.isNotEmpty;
    final data = await _post('/api/ai/generate', {
      // The service routes by model; this only has to be non-empty.
      'provider': 'auto',
      'mediaType': 'video',
      'model': model,
      'scene': i2v ? 'image-to-video' : 'text-to-video',
      'prompt': prompt,
      'options': {
        ...options,
        'sound': true,
        if (i2v) 'image_input': [imageUrl],
      },
    });
    final id = data is Map ? data['id'] : null;
    if (id == null || '$id'.isEmpty) {
      throw const MovoaException(
          'movoa.ai accepted the run but returned no id');
    }
    return '$id';
  }

  /// Look up a run.
  Future<MovoaStatus> status(String id) async {
    final data = await _post('/api/ai/query', {'taskId': id});
    return MovoaStatus(
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{});
  }

  /// Credits left on the account.
  Future<int> credits() async {
    final data = await _post('/api/user/get-user-credits', null);
    final n = data is Map ? data['remainingCredits'] : null;
    if (n is! num) {
      throw const MovoaException('movoa.ai returned no credit balance');
    }
    return n.toInt();
  }

  /// Generate one clip with sound and return its URL.
  Future<String> generateVideo(String prompt,
      {String model = movoaDefaultModel,
      String? imageUrl,
      Map<String, Object?> options = const {}}) async {
    final id = await submit(prompt,
        model: model, imageUrl: imageUrl, options: options);
    return (await waitFor(id)).videoUrl!;
  }

  /// Poll a submitted run until it succeeds; throws
  /// [MovoaGenerationException] when it fails or is canceled and
  /// [MovoaTimeoutException] when [timeout] runs out.
  Future<MovoaStatus> waitFor(String id) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      MovoaStatus? st;
      try {
        st = await status(id);
      } on MovoaException catch (e) {
        if (e.runtimeType != MovoaException) rethrow;
        // only a dropped poll is retried
      }
      if (st != null && st.isSuccess) {
        if (st.videoUrl == null) {
          throw MovoaGenerationException('run $id finished with no video',
              taskId: id);
        }
        return st;
      }
      if (st != null && st.isFailed) {
        final why = st.errorMessage == null ? '' : ': ${st.errorMessage}';
        throw MovoaGenerationException('run $id ${st.status}$why',
            taskId: id,
            errorMessage: st.errorMessage,
            failureKind: st.failureKind);
      }
      if (DateTime.now().add(pollEvery).isAfter(deadline)) {
        throw MovoaTimeoutException(
            'run $id is still generating; check it later with status()',
            taskId: id);
      }
      await Future<void>.delayed(pollEvery);
    }
  }

  /// Close the underlying HTTP client.
  void close() => _client.close();

  Future<Object?> _post(String path, Object? body) async {
    if (apiKey.isEmpty) {
      throw const MovoaAuthException('No API key set. $_keyHint');
    }
    final http.Response res;
    try {
      res = await _client.post(Uri.parse('$baseUrl$path'),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
            'User-Agent': 'movoa-dart/$movoaVersion',
          },
          body: jsonEncode(body ?? const {}));
    } catch (e) {
      throw MovoaException('Could not reach movoa.ai: $e');
    }
    Object? parsed;
    try {
      parsed = jsonDecode(res.body);
    } catch (_) {
      parsed = null;
    }
    return checkResponse(res.statusCode, parsed);
  }
}
