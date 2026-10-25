import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:movoa/movoa.dart';
import 'package:test/test.dart';

/// A client whose every answer comes from [answer], recording request bodies.
Movoa fake(
    List<(String, Map)> calls, (int, Object?) Function(String path) answer,
    {Duration timeout = const Duration(minutes: 30)}) {
  return Movoa(
      apiKey: 'sk-test',
      baseUrl: 'https://t',
      pollEvery: Duration.zero,
      timeout: timeout,
      client: MockClient((r) async {
        expect(r.headers['Authorization'], 'Bearer sk-test');
        calls.add((r.url.path, jsonDecode(r.body) as Map));
        final (status, body) = answer(r.url.path);
        return http.Response(body is String ? body : jsonEncode(body), status);
      }));
}

Map ok(Object data) => {'code': 0, 'message': 'ok', 'data': data};

Future<Type> errorOf(int status, Object? body) async {
  try {
    await fake([], (_) => (status, body)).submit('x');
  } on MovoaException catch (e) {
    return e.runtimeType;
  }
  fail('no error for $status $body');
}

void main() {
  test('text to video: submit, wait through the queue, return videos[0]',
      () async {
    final calls = <(String, Map)>[];
    var polls = 0;
    final c = fake(calls, (path) {
      if (path == '/api/ai/generate')
        return (200, ok({'id': 't1', 'status': 'pending'}));
      return polls++ == 0
          ? (
              200,
              ok({
                'id': 't1',
                'status': 'processing',
                'queued': true,
                'queueEta': 60
              })
            )
          : (
              200,
              ok({
                'id': 't1',
                'status': 'success',
                'videos': ['https://cdn.movoa.ai/v.mp4']
              })
            );
    });
    expect(
        await c.generateVideo('a fox in snow'), 'https://cdn.movoa.ai/v.mp4');
    expect(calls[0].$1, '/api/ai/generate');
    expect(calls[0].$2, {
      'provider': 'auto',
      'mediaType': 'video',
      'model': 'minimax-h3',
      'scene': 'text-to-video',
      'prompt': 'a fox in snow',
      'options': {'sound': true},
    });
    expect(calls[1].$1, '/api/ai/query');
    expect(calls[1].$2, {'taskId': 't1'});
    expect(calls.length, 3);
  });

  test('imageUrl switches to image-to-video and options pass through',
      () async {
    final calls = <(String, Map)>[];
    final c = fake(calls, (_) => (200, ok({'id': 't2', 'status': 'pending'})));
    expect(
        await c.submit('the statue turns',
            model: 'seedance-2-5',
            imageUrl: 'https://x/y.jpg',
            options: {'duration': 10}),
        't2');
    expect(calls[0].$2['scene'], 'image-to-video');
    expect(calls[0].$2['options'], {
      'duration': 10,
      'sound': true,
      'image_input': ['https://x/y.jpg'],
    });
  });

  test('status and credits', () async {
    final st = await fake(
        [],
        (_) => (
              200,
              ok({
                'id': 't3',
                'status': 'processing',
                'queued': true,
                'queueEta': 120
              })
            )).status('t3');
    expect([st.id, st.isSuccess, st.queued, st.queueEta, st.videoUrl],
        ['t3', false, true, 120, null]);
    expect(await fake([], (_) => (200, ok({'remainingCredits': 42}))).credits(),
        42);
  });

  test('failed and canceled runs throw MovoaGenerationException', () async {
    await expectLater(
        fake(
            [],
            (_) => (
                  200,
                  ok({
                    'id': 't4',
                    'status': 'failed',
                    'errorMessage': 'provider down',
                    'failureKind': 'upstream'
                  })
                )).waitFor('t4'),
        throwsA(isA<MovoaGenerationException>()
            .having((e) => e.taskId, 'taskId', 't4')
            .having((e) => e.errorMessage, 'errorMessage', 'provider down')
            .having((e) => e.message, 'message', contains('provider down'))));
    await expectLater(
        fake([], (_) => (200, ok({'id': 't5', 'status': 'canceled'})))
            .waitFor('t5'),
        throwsA(isA<MovoaGenerationException>()));
  });

  test('timeout carries the task id', () async {
    await expectLater(
        fake(
                [],
                (_) => (
                      200,
                      ok({
                        'id': 't6',
                        'status': 'processing',
                        'queued': true,
                        'queueEta': 60
                      })
                    ),
                timeout: Duration.zero)
            .waitFor('t6'),
        throwsA(isA<MovoaTimeoutException>()
            .having((e) => e.taskId, 'taskId', 't6')));
  });

  test('error mapping', () async {
    expect(
        await errorOf(401, {
          'code': -1,
          'message':
              'Invalid API key. Create one at https://movoa.ai/settings/apikeys',
          'data': {'reason': 'invalid_api_key'}
        }),
        MovoaAuthException);
    expect(
        await errorOf(200, {
          'code': -1,
          'message': 'insufficient credits',
          'data': {'reason': 'insufficient_credits'}
        }),
        MovoaQuotaException);
    expect(
        await errorOf(200, {
          'code': -1,
          'message': 'This model or quality needs a plan.',
          'data': {'reason': 'plan_required'}
        }),
        MovoaPlanException);
    expect(
        await errorOf(200, {
          'code': -1,
          'message': 'busy',
          'data': {'reason': 'concurrency'}
        }),
        MovoaBusyException);
    expect(await errorOf(200, {'code': -2, 'message': 'blocked'}),
        MovoaRejectedException);
    expect(await errorOf(200, {'code': -3, 'message': 'cooldown'}),
        MovoaRejectedException);
    expect(
        await errorOf(200,
            {'code': -1, 'message': 'generation failed, please try again'}),
        MovoaException);
    expect(await errorOf(502, '<html>bad gateway</html>'), MovoaException);
  });

  test('credits code -1 no auth -> MovoaAuthException with the key hint',
      () async {
    await expectLater(
        fake(
            [],
            (_) => (
                  200,
                  {'code': -1, 'message': 'no auth, please sign in'}
                )).credits(),
        throwsA(isA<MovoaAuthException>().having(
            (e) => e.message, 'message', contains('/settings/apikeys'))));
  });

  test('no key -> MovoaAuthException without a request', () async {
    final c = Movoa(
        apiKey: '',
        baseUrl: 'https://t',
        client: MockClient((_) async => fail('must not send')));
    await expectLater(c.credits(), throwsA(isA<MovoaAuthException>()));
  });
}
