import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bmm_auto_motors/core/errors/api_exception.dart';
import 'package:bmm_auto_motors/core/network/api_client.dart';
import 'package:bmm_auto_motors/core/network/api_transport.dart';
import 'package:bmm_auto_motors/core/security/credential_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

TokenPair _activePair({
  String access = 'valid-access',
  String refresh = 'valid-refresh',
}) =>
    TokenPair(
      accessToken: access,
      refreshToken: refresh,
      accessExpiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
    );

void main() {
  final baseUrl = Uri.parse('https://staging.example.test');

  test('sends documented login fields and stores only returned token pair',
      () async {
    final storage = MemoryCredentialStore();
    final transport = CallbackTransport((request) async {
      expect(request.uri.path, '/api/v1/native/auth/login');
      expect(request.body, {'login_name': 'owner', 'password': 'secret'});
      return ApiResponse(
        statusCode: 200,
        body: tokenResponse(access: 'a', refresh: 'r'),
      );
    });
    final api =
        ApiClient(baseUrl: baseUrl, transport: transport, credentials: storage);
    await api.login('owner', 'secret');
    expect(storage.pair?.accessToken, 'a');
    expect(storage.pair?.refreshToken, 'r');
  });

  test('turns invalid credentials into a generic message without server detail',
      () async {
    final api = ApiClient(
      baseUrl: baseUrl,
      transport: CallbackTransport(
        (_) async => const ApiResponse(
          statusCode: 401,
          body: {'detail': 'secret-specific detail'},
        ),
      ),
      credentials: MemoryCredentialStore(),
    );
    await expectLater(
      api.login('owner', 'bad'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.message,
          'message',
          isNot(contains('secret-specific')),
        ),
      ),
    );
  });

  test(
      'restored role comes from /me and authenticated requests use bearer token',
      () async {
    final storage = MemoryCredentialStore()..pair = _activePair();
    final transport = CallbackTransport((request) async {
      expect(request.headers['Authorization'], 'Bearer valid-access');
      return ApiResponse(statusCode: 200, body: meResponse(role: 'OWNER'));
    });
    final api =
        ApiClient(baseUrl: baseUrl, transport: transport, credentials: storage);
    expect((await api.me()).role, 'OWNER');
  });

  test('concurrent expired sessions share a single refresh rotation', () async {
    final storage = MemoryCredentialStore()
      ..pair = TokenPair(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
        accessExpiresAt:
            DateTime.now().toUtc().subtract(const Duration(seconds: 1)),
      );
    final refreshStarted = Completer<void>();
    final finishRefresh = Completer<ApiResponse>();
    final transport = CallbackTransport((request) async {
      if (request.uri.path.endsWith('/refresh')) {
        expect(request.body, {'refresh_token': 'old-refresh'});
        refreshStarted.complete();
        return finishRefresh.future;
      }
      if (request.uri.path.endsWith('/me')) {
        return ApiResponse(statusCode: 200, body: meResponse());
      }
      throw StateError('Unexpected request');
    });
    final api =
        ApiClient(baseUrl: baseUrl, transport: transport, credentials: storage);
    final first = api.me();
    final second = api.me();
    await refreshStarted.future;
    finishRefresh.complete(
      ApiResponse(
        statusCode: 200,
        body: tokenResponse(
          access: 'rotated-access',
          refresh: 'rotated-refresh',
        ),
      ),
    );
    final users = await Future.wait([first, second]);
    expect(users, hasLength(2));
    expect(
      transport.requests
          .where((request) => request.uri.path.endsWith('/refresh')),
      hasLength(1),
    );
    expect(storage.pair?.refreshToken, 'rotated-refresh');
    expect(
      transport.requests
          .where((request) => request.uri.path.endsWith('/me'))
          .length,
      2,
    );
  });

  test('concurrent unauthorized responses rotate once and retry once',
      () async {
    final storage = MemoryCredentialStore()
      ..pair = _activePair(
        access: 'old-access',
        refresh: 'old-refresh',
      );
    final refreshStarted = Completer<void>();
    final finishRefresh = Completer<ApiResponse>();
    var meCalls = 0;
    final transport = CallbackTransport((request) async {
      if (request.uri.path.endsWith('/refresh')) {
        refreshStarted.complete();
        return finishRefresh.future;
      }
      if (request.uri.path.endsWith('/me')) {
        meCalls++;
        if (meCalls <= 2) return const ApiResponse(statusCode: 401);
        expect(request.headers['Authorization'], 'Bearer rotated-access');
        return ApiResponse(statusCode: 200, body: meResponse());
      }
      throw StateError('Unexpected request');
    });
    final api =
        ApiClient(baseUrl: baseUrl, transport: transport, credentials: storage);
    final first = api.me();
    final second = api.me();
    await refreshStarted.future;
    finishRefresh.complete(
      ApiResponse(
        statusCode: 200,
        body: tokenResponse(
          access: 'rotated-access',
          refresh: 'rotated-refresh',
        ),
      ),
    );
    await Future.wait([first, second]);
    expect(
      transport.requests
          .where((request) => request.uri.path.endsWith('/refresh')),
      hasLength(1),
    );
    expect(meCalls, 4);
  });

  test('logout clears local credentials even if the server request fails',
      () async {
    final storage = MemoryCredentialStore()
      ..pair = TokenPair(
        accessToken: 'a',
        refreshToken: 'r',
        accessExpiresAt: DateTime.utc(2026),
      );
    final api = ApiClient(
      baseUrl: baseUrl,
      transport: CallbackTransport((_) async => throw Exception('offline')),
      credentials: storage,
    );
    await expectLater(api.logout(), throwsA(isA<ApiException>()));
    expect(storage.pair, isNull);
  });

  test(
      'authenticated GET, POST, and PATCH attach bearer token and query parameters',
      () async {
    final storage = MemoryCredentialStore()..pair = _activePair();
    final transport = CallbackTransport((request) async {
      expect(request.headers['Authorization'], 'Bearer valid-access');
      expect(request.headers['Accept'], 'application/json');
      return switch (request.method) {
        'GET' => () {
            expect(request.uri.path, '/api/v1/products');
            expect(request.uri.queryParameters, {
              'q': 'brake',
              'approval_status': 'approved',
            });
            return const ApiResponse(
              statusCode: 200,
              body: {
                'items': [
                  {'id': 'p1', 'name': 'Brake Pad'},
                ],
                'limit': 50,
              },
            );
          }(),
        'POST' => () {
            expect(request.uri.path, '/api/v1/products');
            expect(request.body, {
              'name': 'Oil Filter',
              'category': 'Engine',
            });
            return const ApiResponse(
              statusCode: 201,
              body: {'id': 'p2', 'name': 'Oil Filter'},
            );
          }(),
        'PATCH' => () {
            expect(request.uri.path, '/api/v1/products/p2');
            expect(request.body, {'description': 'Heavy duty'});
            return const ApiResponse(
              statusCode: 200,
              body: {
                'id': 'p2',
                'name': 'Oil Filter',
                'description': 'Heavy duty',
              },
            );
          }(),
        _ => throw StateError('Unexpected method ${request.method}'),
      };
    });
    final api =
        ApiClient(baseUrl: baseUrl, transport: transport, credentials: storage);

    final listResult = await api.get(
      '/api/v1/products',
      queryParameters: {'q': 'brake', 'approval_status': 'approved'},
    ) as Map<String, dynamic>;
    final created = await api.post(
      '/api/v1/products',
      body: {'name': 'Oil Filter', 'category': 'Engine'},
    ) as Map<String, dynamic>;
    final updated = await api.patch(
      '/api/v1/products/p2',
      body: {'description': 'Heavy duty'},
    ) as Map<String, dynamic>;

    expect((listResult['items'] as List<dynamic>).single['id'], 'p1');
    expect(created['id'], 'p2');
    expect(updated['description'], 'Heavy duty');
  });

  test('POST and PATCH refresh and retry once with the rotated token on 401',
      () async {
    final storage = MemoryCredentialStore()
      ..pair = _activePair(access: 'stale-token', refresh: 'refresh-1');
    var postAttempts = 0;
    final transport = CallbackTransport((request) async {
      if (request.uri.path == '/api/v1/native/auth/refresh') {
        expect(request.body, {'refresh_token': 'refresh-1'});
        return ApiResponse(
          statusCode: 200,
          body: tokenResponse(access: 'fresh-token', refresh: 'refresh-2'),
        );
      }
      if (request.method == 'PATCH' &&
          request.uri.path == '/api/v1/products/123') {
        postAttempts++;
        if (postAttempts == 1) {
          expect(request.headers['Authorization'], 'Bearer stale-token');
          return const ApiResponse(statusCode: 401);
        }
        expect(request.headers['Authorization'], 'Bearer fresh-token');
        expect(request.body, {'name': 'Updated Rotor'});
        return const ApiResponse(
          statusCode: 200,
          body: {'id': '123', 'name': 'Updated Rotor'},
        );
      }
      throw StateError('Unexpected request ${request.method} ${request.uri}');
    });
    final api =
        ApiClient(baseUrl: baseUrl, transport: transport, credentials: storage);

    final result = await api.patch(
      '/api/v1/products/123',
      body: {'name': 'Updated Rotor'},
    ) as Map<String, dynamic>;

    expect(result['name'], 'Updated Rotor');
    expect(postAttempts, 2);
    expect(storage.pair?.accessToken, 'fresh-token');
    expect(storage.pair?.refreshToken, 'refresh-2');
  });

  test(
      'failed refresh clears credentials and does not enter an infinite retry loop',
      () async {
    final storage = MemoryCredentialStore()
      ..pair = _activePair(access: 'expired-on-server', refresh: 'bad-refresh');
    var productCalls = 0;
    var refreshCalls = 0;
    final transport = CallbackTransport((request) async {
      if (request.uri.path == '/api/v1/products') {
        productCalls++;
        return const ApiResponse(statusCode: 401);
      }
      if (request.uri.path == '/api/v1/native/auth/refresh') {
        refreshCalls++;
        return const ApiResponse(
          statusCode: 401,
          body: {'detail': 'Invalid or expired session.'},
        );
      }
      throw StateError('Unexpected request');
    });
    final api =
        ApiClient(baseUrl: baseUrl, transport: transport, credentials: storage);

    await expectLater(
      api.get('/api/v1/products'),
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401),
      ),
    );
    expect(productCalls, 1);
    expect(refreshCalls, 1);
    expect(storage.pair, isNull);
  });

  test(
      'pre-emptively refreshed request that still receives 401 does not refresh a second time',
      () async {
    final storage = MemoryCredentialStore()
      ..pair = TokenPair(
        accessToken: 'expired-local',
        refreshToken: 'refresh-1',
        accessExpiresAt:
            DateTime.now().toUtc().subtract(const Duration(seconds: 5)),
      );
    var refreshCalls = 0;
    var productCalls = 0;
    final transport = CallbackTransport((request) async {
      if (request.uri.path == '/api/v1/native/auth/refresh') {
        refreshCalls++;
        return ApiResponse(
          statusCode: 200,
          body: tokenResponse(access: 'rotated-access', refresh: 'refresh-2'),
        );
      }
      if (request.uri.path == '/api/v1/products') {
        productCalls++;
        return const ApiResponse(statusCode: 401);
      }
      throw StateError('Unexpected request');
    });
    final api =
        ApiClient(baseUrl: baseUrl, transport: transport, credentials: storage);

    await expectLater(
      api.get('/api/v1/products'),
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401),
      ),
    );
    expect(refreshCalls, 1);
    expect(productCalls, 1);
    expect(storage.pair, isNull);
  });

  test(
      'multipart upload preserves bytes, filename, content type, and replays after refresh',
      () async {
    final storage = MemoryCredentialStore()
      ..pair =
          _activePair(access: 'initial-access', refresh: 'initial-refresh');
    final sourceBytes = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    var uploadAttempts = 0;
    final transport = CallbackTransport((request) async {
      if (request.uri.path == '/api/v1/native/auth/refresh') {
        return ApiResponse(
          statusCode: 200,
          body: tokenResponse(
            access: 'refreshed-access',
            refresh: 'refreshed-refresh',
          ),
        );
      }
      expect(request.method, 'POST');
      expect(request.uri.path, '/api/v1/products/prod-1/image');
      final payload = request.body as MultipartFilePayload;
      expect(payload.fieldName, 'file');
      expect(payload.filename, 'clutch-plate.png');
      expect(payload.contentType, 'image/png');
      expect(
        payload.bytes,
        Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
      );
      // Mutate the returned view to verify the stored payload remains intact for replay.
      payload.bytes[0] = 0x00;

      uploadAttempts++;
      if (uploadAttempts == 1) {
        expect(request.headers['Authorization'], 'Bearer initial-access');
        return const ApiResponse(statusCode: 401);
      }
      expect(request.headers['Authorization'], 'Bearer refreshed-access');
      return const ApiResponse(
        statusCode: 200,
        body: {
          'id': 'prod-1',
          'image_url': '/api/v1/products/prod-1/image',
        },
      );
    });
    final api =
        ApiClient(baseUrl: baseUrl, transport: transport, credentials: storage);

    final response = await api.uploadMultipart(
      '/api/v1/products/prod-1/image',
      bytes: sourceBytes,
      filename: 'clutch-plate.png',
      contentType: 'image/png',
    ) as Map<String, dynamic>;

    expect(uploadAttempts, 2);
    expect(response['image_url'], '/api/v1/products/prod-1/image');
  });

  test(
      'authenticated image retrieval returns raw binary bytes and retries on 401',
      () async {
    final storage = MemoryCredentialStore()
      ..pair = _activePair(access: 'first-token', refresh: 'first-refresh');
    // Binary sequence with invalid UTF-8 and non-JSON bytes.
    final expectedBytes = Uint8List.fromList(
      [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0xFE, 0x80, 0xFF, 0xD9],
    );
    var imageAttempts = 0;
    final transport = CallbackTransport((request) async {
      if (request.uri.path == '/api/v1/native/auth/refresh') {
        return ApiResponse(
          statusCode: 200,
          body: tokenResponse(
            access: 'second-token',
            refresh: 'second-refresh',
          ),
        );
      }
      expect(request.method, 'GET');
      expect(request.uri.path, '/api/v1/products/prod-1/image');
      expect(request.responseType, ApiResponseType.bytes);
      imageAttempts++;
      if (imageAttempts == 1) {
        expect(request.headers['Authorization'], 'Bearer first-token');
        return const ApiResponse(statusCode: 401);
      }
      expect(request.headers['Authorization'], 'Bearer second-token');
      return ApiResponse(statusCode: 200, body: expectedBytes);
    });
    final api =
        ApiClient(baseUrl: baseUrl, transport: transport, credentials: storage);

    final actualBytes =
        await api.getImageBytes('/api/v1/products/prod-1/image');
    expect(actualBytes, expectedBytes);
    expect(imageAttempts, 2);
  });

  test('maps HTTP error status codes consistently to ApiException', () async {
    const cases = <int, String>{
      401: 'Your session has expired. Please sign in again.',
      403: 'This account cannot perform that action.',
      404: 'The requested item could not be found.',
      409: 'This action conflicts with the current record state.',
      413: 'The selected image exceeds the upload size limit.',
      415: 'Only JPEG, PNG, and WebP images are accepted.',
      422: 'Check the entered information and try again.',
      429: 'Sign-in is temporarily unavailable. Try again later.',
      500: 'The service is temporarily unavailable. Try again later.',
      503: 'The service is temporarily unavailable. Try again later.',
    };

    for (final entry in cases.entries) {
      final storage = MemoryCredentialStore()..pair = _activePair();
      final transport = CallbackTransport((request) async {
        if (request.uri.path == '/api/v1/native/auth/refresh') {
          return ApiResponse(
            statusCode: 200,
            body: tokenResponse(access: 'rotated', refresh: 'rotated-r'),
          );
        }
        return ApiResponse(
          statusCode: entry.key,
          body: {'detail': 'internal-server-detail'},
        );
      });
      final api = ApiClient(
        baseUrl: baseUrl,
        transport: transport,
        credentials: storage,
      );

      await expectLater(
        api.post('/api/v1/products', body: {'name': 'Part'}),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', entry.key)
              .having((e) => e.message, 'message', entry.value)
              .having(
                (e) => e.message,
                'no leaked detail',
                isNot(contains('internal-server-detail')),
              ),
        ),
      );
    }
  });

  test(
      'maps missing credentials, network failures, and unexpected payloads to ApiException',
      () async {
    final unauthenticatedApi = ApiClient(
      baseUrl: baseUrl,
      transport: CallbackTransport(
        (_) async => throw StateError('Transport should not be called'),
      ),
      credentials: MemoryCredentialStore(),
    );
    await expectLater(
      unauthenticatedApi.get('/api/v1/products'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.message, 'message', 'Please sign in to continue.'),
      ),
    );

    final networkApi = ApiClient(
      baseUrl: baseUrl,
      transport: CallbackTransport(
        (_) async => throw const SocketException('Connection refused'),
      ),
      credentials: MemoryCredentialStore()..pair = _activePair(),
    );
    await expectLater(
      networkApi.get('/api/v1/products'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', isNull)
            .having(
              (e) => e.message,
              'message',
              'Unable to reach BMM Auto Motors. Check the connection and try again.',
            ),
      ),
    );

    final invalidJsonBodyApi = ApiClient(
      baseUrl: baseUrl,
      transport: CallbackTransport(
        (_) async => const ApiResponse(statusCode: 200, body: 'not-a-json-map'),
      ),
      credentials: MemoryCredentialStore()..pair = _activePair(),
    );
    await expectLater(
      invalidJsonBodyApi.get('/api/v1/products'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', isNull)
            .having(
              (e) => e.message,
              'message',
              'The server returned an invalid response.',
            ),
      ),
    );

    final invalidImageBodyApi = ApiClient(
      baseUrl: baseUrl,
      transport: CallbackTransport(
        (_) async => const ApiResponse(statusCode: 200, body: <int>[]),
      ),
      credentials: MemoryCredentialStore()..pair = _activePair(),
    );
    await expectLater(
      invalidImageBodyApi.getBytes('/api/v1/products/p1/image'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', isNull)
            .having(
              (e) => e.message,
              'message',
              'The server returned an invalid image response.',
            ),
      ),
    );
  });

  test(
      'IoApiTransport encodes multipart uploads and returns raw binary image bytes',
      () async {
    final rawImage = Uint8List.fromList(
      [0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x43, 0x80, 0xFF, 0xD9],
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    server.listen((HttpRequest request) async {
      if (request.uri.path == '/upload') {
        final contentType = request.headers.contentType;
        expect(contentType?.mimeType, 'multipart/form-data');
        final boundary = contentType?.parameters['boundary'];
        expect(boundary, isNotNull);
        final bodyBytes = await request.fold<BytesBuilder>(
          BytesBuilder(copy: false),
          (builder, chunk) => builder..add(chunk),
        );
        final bodyText = latin1.decode(bodyBytes.takeBytes());
        expect(
          bodyText,
          contains(
            'Content-Disposition: form-data; name="file"; filename="part.jpg"',
          ),
        );
        expect(bodyText, contains('Content-Type: image/jpeg'));
        expect(bodyText, contains(latin1.decode(rawImage)));
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'id': 'uploaded-1'}));
        await request.response.close();
        return;
      }
      if (request.uri.path == '/image') {
        request.response
          ..statusCode = 200
          ..headers.set(HttpHeaders.contentTypeHeader, 'image/jpeg')
          ..add(rawImage);
        await request.response.close();
        return;
      }
      request.response.statusCode = 404;
      await request.response.close();
    });

    final transport = IoApiTransport();
    addTearDown(() => transport.close(force: true));
    final serverUri = Uri.parse('http://${server.address.host}:${server.port}');

    final uploadResponse = await transport.send(
      ApiRequest(
        method: 'POST',
        uri: serverUri.resolve('/upload'),
        body: MultipartFilePayload(
          bytes: rawImage,
          filename: 'part.jpg',
          contentType: 'image/jpeg',
        ),
      ),
    );
    expect(uploadResponse.statusCode, 200);
    expect(uploadResponse.body, {'id': 'uploaded-1'});

    final imageResponse = await transport.send(
      ApiRequest(
        method: 'GET',
        uri: serverUri.resolve('/image'),
        responseType: ApiResponseType.bytes,
      ),
    );
    expect(imageResponse.statusCode, 200);
    expect(imageResponse.body, rawImage);
  });

  test(
      'stale caller attempting refresh after another caller refresh fails does not send second refresh',
      () async {
    final callerBReadOldPair = Completer<void>();
    final callerBHeldAtBarrier = Completer<void>();
    final releaseCallerB = Completer<ApiResponse>();
    final refreshStarted = Completer<void>();
    final finishFirstRefresh = Completer<ApiResponse>();
    var readCount = 0;
    var refreshNetworkCalls = 0;

    final storage = _HookedCredentialStore(
      initial: _activePair(
        access: 'old-access',
        refresh: 'shared-refresh',
      ),
      onRead: () async {
        readCount++;
        if (readCount == 2 && !callerBReadOldPair.isCompleted) {
          callerBReadOldPair.complete();
        }
      },
    );

    final transport = CallbackTransport((request) async {
      if (request.uri.path == '/api/v1/products' &&
          request.uri.queryParameters['caller'] == 'A') {
        expect(request.headers['Authorization'], 'Bearer old-access');
        return const ApiResponse(statusCode: 401);
      }
      if (request.uri.path == '/api/v1/products' &&
          request.uri.queryParameters['caller'] == 'B') {
        expect(request.headers['Authorization'], 'Bearer old-access');
        if (!callerBHeldAtBarrier.isCompleted) {
          callerBHeldAtBarrier.complete();
        }
        return releaseCallerB.future;
      }
      if (request.uri.path == '/api/v1/native/auth/refresh') {
        refreshNetworkCalls++;
        expect(request.body, {'refresh_token': 'shared-refresh'});
        if (!refreshStarted.isCompleted) {
          refreshStarted.complete();
        }
        return finishFirstRefresh.future;
      }
      throw StateError('Unexpected request ${request.uri}');
    });

    final api =
        ApiClient(baseUrl: baseUrl, transport: transport, credentials: storage);

    // 1. Caller A and Caller B both begin concurrently with the same old TokenPair.
    final callerA = api.get(
      '/api/v1/products',
      queryParameters: const {'caller': 'A'},
    );
    final callerB = api.get(
      '/api/v1/products',
      queryParameters: const {'caller': 'B'},
    );

    // 2-4. Hold Caller A's refresh response until Caller B has demonstrably
    // completed its initial credential read of the old pair and is held at its
    // controlled barrier.
    await Future.wait([
      callerBReadOldPair.future,
      callerBHeldAtBarrier.future,
      refreshStarted.future,
    ]);

    // 5. Caller A's refresh fails and its credentials are cleared.
    finishFirstRefresh.complete(
      const ApiResponse(
        statusCode: 401,
        body: {'detail': 'Invalid or expired session.'},
      ),
    );
    await expectLater(
      callerA,
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401),
      ),
    );
    expect(storage.pair, isNull);
    expect(api.consumedRefreshTokens, contains('shared-refresh'));

    // 6. Release Caller B after Caller A's refresh has already failed.
    releaseCallerB.complete(const ApiResponse(statusCode: 401));

    // 7-8. Assert Caller B fails with 401, does not submit the refresh token a
    // second time, and credentials remain cleared.
    await expectLater(
      callerB,
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401),
      ),
    );
    expect(refreshNetworkCalls, 1);
    expect(
      transport.requests
          .where((r) => r.uri.path == '/api/v1/native/auth/refresh'),
      hasLength(1),
    );
    expect(storage.pair, isNull);
  });

  test(
      'logout occurring while a refresh is in flight prevents credential write',
      () async {
    final storage = MemoryCredentialStore()
      ..pair = TokenPair(
        accessToken: 'expired-access',
        refreshToken: 'in-flight-refresh',
        accessExpiresAt:
            DateTime.now().toUtc().subtract(const Duration(seconds: 5)),
      );
    final refreshStarted = Completer<void>();
    final finishRefresh = Completer<ApiResponse>();
    var logoutCalled = false;

    final transport = CallbackTransport((request) async {
      if (request.uri.path == '/api/v1/native/auth/refresh') {
        refreshStarted.complete();
        return finishRefresh.future;
      }
      if (request.uri.path == '/api/v1/native/auth/logout') {
        logoutCalled = true;
        return const ApiResponse(statusCode: 204);
      }
      throw StateError('Unexpected request ${request.uri}');
    });

    final api =
        ApiClient(baseUrl: baseUrl, transport: transport, credentials: storage);
    final pendingGet = api.get('/api/v1/products');
    await refreshStarted.future;

    await api.logout();
    expect(logoutCalled, isTrue);
    expect(storage.pair, isNull);

    finishRefresh.complete(
      ApiResponse(
        statusCode: 200,
        body: tokenResponse(
          access: 'zombie-access',
          refresh: 'zombie-refresh',
        ),
      ),
    );

    await expectLater(
      pendingGet,
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401),
      ),
    );
    expect(
      transport.requests
          .where((r) => r.uri.path == '/api/v1/native/auth/refresh'),
      hasLength(1),
    );
    expect(storage.pair, isNull);
  });

  test(
      'newer login completing while an older refresh is in flight is not overwritten',
      () async {
    final storage = MemoryCredentialStore()
      ..pair = TokenPair(
        accessToken: 'old-expired-access',
        refreshToken: 'old-refresh',
        accessExpiresAt:
            DateTime.now().toUtc().subtract(const Duration(seconds: 5)),
      );
    final refreshStarted = Completer<void>();
    final finishRefresh = Completer<ApiResponse>();

    final transport = CallbackTransport((request) async {
      if (request.uri.path == '/api/v1/native/auth/refresh') {
        refreshStarted.complete();
        return finishRefresh.future;
      }
      if (request.uri.path == '/api/v1/native/auth/login') {
        return ApiResponse(
          statusCode: 200,
          body: tokenResponse(
            access: 'newer-login-access',
            refresh: 'newer-login-refresh',
          ),
        );
      }
      if (request.uri.path == '/api/v1/products') {
        expect(request.headers['Authorization'], 'Bearer newer-login-access');
        return const ApiResponse(statusCode: 200, body: {'items': <Object>[]});
      }
      throw StateError('Unexpected request ${request.uri}');
    });

    final api =
        ApiClient(baseUrl: baseUrl, transport: transport, credentials: storage);
    final pendingGet = api.get('/api/v1/products');
    await refreshStarted.future;

    await api.login('owner', 'new-secret');
    expect(storage.pair?.accessToken, 'newer-login-access');

    finishRefresh.complete(
      ApiResponse(
        statusCode: 200,
        body: tokenResponse(
          access: 'stale-rotated-access',
          refresh: 'stale-rotated-refresh',
        ),
      ),
    );

    await pendingGet;
    expect(
      transport.requests
          .where((r) => r.uri.path == '/api/v1/native/auth/refresh'),
      hasLength(1),
    );
    expect(storage.pair?.accessToken, 'newer-login-access');
    expect(storage.pair?.refreshToken, 'newer-login-refresh');
  });

  test('older failed refresh does not clear newer credentials', () async {
    final storage = MemoryCredentialStore()
      ..pair = TokenPair(
        accessToken: 'old-expired-access',
        refreshToken: 'old-refresh',
        accessExpiresAt:
            DateTime.now().toUtc().subtract(const Duration(seconds: 5)),
      );
    final refreshStarted = Completer<void>();
    final finishRefresh = Completer<ApiResponse>();

    final transport = CallbackTransport((request) async {
      if (request.uri.path == '/api/v1/native/auth/refresh') {
        refreshStarted.complete();
        return finishRefresh.future;
      }
      if (request.uri.path == '/api/v1/native/auth/login') {
        return ApiResponse(
          statusCode: 200,
          body: tokenResponse(
            access: 'fresh-login-access',
            refresh: 'fresh-login-refresh',
          ),
        );
      }
      throw StateError('Unexpected request ${request.uri}');
    });

    final api =
        ApiClient(baseUrl: baseUrl, transport: transport, credentials: storage);
    final pendingGet = api.get('/api/v1/products');
    await refreshStarted.future;

    await api.login('owner', 'new-secret');
    expect(storage.pair?.accessToken, 'fresh-login-access');

    finishRefresh.complete(const ApiResponse(statusCode: 401));
    await expectLater(
      pendingGet,
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401),
      ),
    );
    expect(
      transport.requests
          .where((r) => r.uri.path == '/api/v1/native/auth/refresh'),
      hasLength(1),
    );
    expect(storage.pair?.accessToken, 'fresh-login-access');
    expect(storage.pair?.refreshToken, 'fresh-login-refresh');
  });

  test('stale 401 response does not clear newer credentials', () async {
    final storage = MemoryCredentialStore()
      ..pair = TokenPair(
        accessToken: 'expired-initial',
        refreshToken: 'refresh-initial',
        accessExpiresAt:
            DateTime.now().toUtc().subtract(const Duration(seconds: 5)),
      );
    final productRequestStarted = Completer<void>();
    final finishProductRequest = Completer<ApiResponse>();

    final transport = CallbackTransport((request) async {
      if (request.uri.path == '/api/v1/native/auth/refresh') {
        return ApiResponse(
          statusCode: 200,
          body: tokenResponse(
            access: 'rotated-before-request',
            refresh: 'rotated-refresh-1',
          ),
        );
      }
      if (request.uri.path == '/api/v1/products') {
        productRequestStarted.complete();
        return finishProductRequest.future;
      }
      if (request.uri.path == '/api/v1/native/auth/login') {
        return ApiResponse(
          statusCode: 200,
          body: tokenResponse(
            access: 'newer-session-access',
            refresh: 'newer-session-refresh',
          ),
        );
      }
      throw StateError('Unexpected request ${request.uri}');
    });

    final api =
        ApiClient(baseUrl: baseUrl, transport: transport, credentials: storage);
    final staleRequest = api.get('/api/v1/products');
    await productRequestStarted.future;

    await api.login('owner', 'new-password');
    expect(storage.pair?.accessToken, 'newer-session-access');

    finishProductRequest.complete(const ApiResponse(statusCode: 401));
    await expectLater(
      staleRequest,
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401),
      ),
    );
    expect(
      transport.requests
          .where((r) => r.uri.path == '/api/v1/native/auth/refresh'),
      hasLength(1),
    );
    expect(storage.pair?.accessToken, 'newer-session-access');
    expect(storage.pair?.refreshToken, 'newer-session-refresh');
  });

  test(
      'logout followed by a newer login does not clear the newer login credentials',
      () async {
    final initialClearEntered = Completer<void>();
    final releaseInitialClear = Completer<void>();
    final logoutRequestStarted = Completer<void>();
    final finishLogoutRequest = Completer<ApiResponse>();
    var clearCount = 0;

    final storage = _HookedCredentialStore(
      initial: _activePair(
        access: 'outgoing-access',
        refresh: 'outgoing-refresh',
      ),
      onRead: () async {},
      onClear: () async {
        clearCount++;
        if (clearCount == 1) {
          initialClearEntered.complete();
          await releaseInitialClear.future;
        }
      },
    );

    final transport = CallbackTransport((request) async {
      if (request.uri.path == '/api/v1/native/auth/logout') {
        logoutRequestStarted.complete();
        return finishLogoutRequest.future;
      }
      if (request.uri.path == '/api/v1/native/auth/login') {
        return ApiResponse(
          statusCode: 200,
          body: tokenResponse(
            access: 'newer-login-access',
            refresh: 'newer-login-refresh',
          ),
        );
      }
      throw StateError('Unexpected request ${request.uri}');
    });

    final api =
        ApiClient(baseUrl: baseUrl, transport: transport, credentials: storage);

    // Start logout and hold inside its initial storage lock.
    final logoutFuture = api.logout();
    await initialClearEntered.future;

    // Queue a newer login while logout's initial lock is held.
    final loginFuture = api.login('owner', 'new-secret');

    // Release logout's initial lock so login completes its HTTP call and
    // storage write while logout is still in flight before its final cleanup.
    releaseInitialClear.complete();
    await logoutRequestStarted.future;
    await loginFuture;
    expect(storage.pair?.accessToken, 'newer-login-access');
    expect(storage.pair?.refreshToken, 'newer-login-refresh');

    // Allow logout's HTTP request and final cleanup lock to complete.
    finishLogoutRequest.complete(const ApiResponse(statusCode: 204));
    await logoutFuture;

    expect(storage.pair?.accessToken, 'newer-login-access');
    expect(storage.pair?.refreshToken, 'newer-login-refresh');
    expect(api.consumedRefreshTokens, contains('outgoing-refresh'));
  });

  test('login completing after logout does not write credentials', () async {
    final storage = MemoryCredentialStore()
      ..pair = _activePair(
        access: 'prior-access',
        refresh: 'prior-refresh',
      );
    final loginRequestStarted = Completer<void>();
    final finishLoginRequest = Completer<ApiResponse>();

    final transport = CallbackTransport((request) async {
      if (request.uri.path == '/api/v1/native/auth/login') {
        loginRequestStarted.complete();
        return finishLoginRequest.future;
      }
      if (request.uri.path == '/api/v1/native/auth/logout') {
        return const ApiResponse(statusCode: 204);
      }
      throw StateError('Unexpected request ${request.uri}');
    });

    final api =
        ApiClient(baseUrl: baseUrl, transport: transport, credentials: storage);

    final pendingLogin = api.login('owner', 'secret');
    await loginRequestStarted.future;

    // Logout occurs while the earlier login request is still in flight.
    await api.logout();
    expect(storage.pair, isNull);
    expect(api.consumedRefreshTokens, contains('prior-refresh'));

    finishLoginRequest.complete(
      ApiResponse(
        statusCode: 200,
        body: tokenResponse(
          access: 'stale-login-access',
          refresh: 'stale-login-refresh',
        ),
      ),
    );

    await expectLater(
      pendingLogin,
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401),
      ),
    );
    expect(storage.pair, isNull);
    expect(api.consumedRefreshTokens, contains('stale-login-refresh'));
  });

  test('stale login response does not overwrite newer login credentials',
      () async {
    final storage = MemoryCredentialStore();
    final firstLoginStarted = Completer<void>();
    final finishFirstLogin = Completer<ApiResponse>();
    var loginCount = 0;

    final transport = CallbackTransport((request) async {
      if (request.uri.path == '/api/v1/native/auth/login') {
        loginCount++;
        if (loginCount == 1) {
          firstLoginStarted.complete();
          return finishFirstLogin.future;
        }
        return ApiResponse(
          statusCode: 200,
          body: tokenResponse(
            access: 'second-login-access',
            refresh: 'second-login-refresh',
          ),
        );
      }
      throw StateError('Unexpected request ${request.uri}');
    });

    final api =
        ApiClient(baseUrl: baseUrl, transport: transport, credentials: storage);

    final firstLogin = api.login('attendant1', 'first-secret');
    await firstLoginStarted.future;

    await api.login('owner', 'second-secret');
    expect(storage.pair?.accessToken, 'second-login-access');
    expect(storage.pair?.refreshToken, 'second-login-refresh');

    finishFirstLogin.complete(
      ApiResponse(
        statusCode: 200,
        body: tokenResponse(
          access: 'first-login-access',
          refresh: 'first-login-refresh',
        ),
      ),
    );

    await expectLater(
      firstLogin,
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401),
      ),
    );
    expect(storage.pair?.accessToken, 'second-login-access');
    expect(storage.pair?.refreshToken, 'second-login-refresh');
    expect(api.consumedRefreshTokens, contains('first-login-refresh'));
  });

  test(
      'bounded consumed refresh-token tracking records tokens on rotation and logout and evicts oldest beyond 64',
      () async {
    final storage = MemoryCredentialStore();
    var rotationIndex = 0;

    final transport = CallbackTransport((request) async {
      if (request.uri.path == '/api/v1/native/auth/refresh') {
        rotationIndex++;
        return ApiResponse(
          statusCode: 200,
          body: tokenResponse(
            access: 'access-$rotationIndex',
            refresh: 'refresh-$rotationIndex',
          ),
        );
      }
      if (request.uri.path == '/api/v1/products') {
        return const ApiResponse(statusCode: 200, body: {'items': <Object>[]});
      }
      if (request.uri.path == '/api/v1/native/auth/logout') {
        return const ApiResponse(statusCode: 204);
      }
      throw StateError('Unexpected request ${request.uri}');
    });

    final api =
        ApiClient(baseUrl: baseUrl, transport: transport, credentials: storage);

    for (var i = 0; i < 66; i++) {
      storage.pair = TokenPair(
        accessToken: 'expired-$i',
        refreshToken: 'refresh-$i',
        accessExpiresAt:
            DateTime.now().toUtc().subtract(const Duration(seconds: 5)),
      );
      await api.get('/api/v1/products');
    }

    expect(
      api.consumedRefreshTokens.length,
      ApiClient.maxConsumedRefreshTokens,
    );
    expect(api.consumedRefreshTokens, isNot(contains('refresh-0')));
    expect(api.consumedRefreshTokens, isNot(contains('refresh-1')));
    expect(api.consumedRefreshTokens.first, 'refresh-2');
    expect(api.consumedRefreshTokens.last, 'refresh-65');
    expect(api.consumedRefreshTokens, isNot(contains('refresh-66')));

    await api.logout();
    expect(
      api.consumedRefreshTokens.length,
      ApiClient.maxConsumedRefreshTokens,
    );
    expect(api.consumedRefreshTokens, isNot(contains('refresh-2')));
    expect(api.consumedRefreshTokens.last, 'refresh-66');
  });

  test(
      'concurrent mixed GET, POST, PATCH, multipart, and binary requests share one refresh',
      () async {
    final storage = MemoryCredentialStore()
      ..pair = TokenPair(
        accessToken: 'expired-access',
        refreshToken: 'refresh-token-1',
        accessExpiresAt:
            DateTime.now().toUtc().subtract(const Duration(seconds: 2)),
      );
    final refreshStarted = Completer<void>();
    final finishRefresh = Completer<ApiResponse>();
    final rawImage = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);

    final transport = CallbackTransport((request) async {
      if (request.uri.path == '/api/v1/native/auth/refresh') {
        if (!refreshStarted.isCompleted) {
          refreshStarted.complete();
        }
        return finishRefresh.future;
      }
      expect(request.headers['Authorization'], 'Bearer shared-rotated-access');
      return switch ((request.method, request.uri.path)) {
        ('GET', '/api/v1/products') =>
          const ApiResponse(statusCode: 200, body: {'items': <Object>[]}),
        ('POST', '/api/v1/products') =>
          const ApiResponse(statusCode: 201, body: {'id': 'new-id'}),
        ('PATCH', '/api/v1/products/p1') =>
          const ApiResponse(statusCode: 200, body: {'id': 'p1'}),
        ('POST', '/api/v1/products/p1/image') =>
          const ApiResponse(statusCode: 200, body: {'id': 'p1'}),
        ('GET', '/api/v1/products/p1/image') =>
          ApiResponse(statusCode: 200, body: rawImage),
        _ => throw StateError('Unexpected ${request.method} ${request.uri}'),
      };
    });

    final api =
        ApiClient(baseUrl: baseUrl, transport: transport, credentials: storage);
    final futures = <Future<Object?>>[
      api.get('/api/v1/products'),
      api.post('/api/v1/products', body: {'name': 'Filter'}),
      api.patch('/api/v1/products/p1', body: {'name': 'Updated Filter'}),
      api.uploadMultipart(
        '/api/v1/products/p1/image',
        bytes: rawImage,
        filename: 'filter.png',
        contentType: 'image/png',
      ),
      api.getBytes('/api/v1/products/p1/image'),
    ];

    await refreshStarted.future;
    finishRefresh.complete(
      ApiResponse(
        statusCode: 200,
        body: tokenResponse(
          access: 'shared-rotated-access',
          refresh: 'shared-rotated-refresh',
        ),
      ),
    );

    final results = await Future.wait(futures);
    expect(results, hasLength(5));
    expect(results.last, rawImage);
    expect(
      transport.requests
          .where((r) => r.uri.path == '/api/v1/native/auth/refresh'),
      hasLength(1),
    );
  });

  test('multipart form fields and constructor validation work as expected',
      () async {
    expect(
      () => MultipartFilePayload(
        bytes: const [],
        filename: 'part.jpg',
        contentType: 'image/jpeg',
      ),
      throwsArgumentError,
    );
    expect(
      () => MultipartFilePayload(
        bytes: const [1, 2],
        filename: '   ',
        contentType: 'image/jpeg',
      ),
      throwsArgumentError,
    );
    expect(
      () => MultipartFilePayload(
        bytes: const [1, 2],
        filename: 'part.jpg',
        contentType: '',
      ),
      throwsArgumentError,
    );
    expect(
      () => MultipartFilePayload(
        bytes: const [1, 2],
        filename: 'part.jpg',
        contentType: 'image/jpeg',
        fieldName: ' ',
      ),
      throwsArgumentError,
    );

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((HttpRequest request) async {
      final bodyBytes = await request.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, chunk) => builder..add(chunk),
      );
      final bodyText = utf8.decode(bodyBytes.takeBytes(), allowMalformed: true);
      expect(
        bodyText,
        contains(
          'Content-Disposition: form-data; name="category"\r\n\r\nEngine\r\n',
        ),
      );
      expect(
        bodyText,
        contains(
          'Content-Disposition: form-data; name="notes"\r\n\r\n heavy-duty\r\n',
        ),
      );
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'ok': true}));
      await request.response.close();
    });

    final transport = IoApiTransport();
    addTearDown(() => transport.close(force: true));
    final response = await transport.send(
      ApiRequest(
        method: 'POST',
        uri: Uri.parse('http://${server.address.host}:${server.port}/upload'),
        body: MultipartFilePayload(
          bytes: const [0xFF, 0xD8, 0xFF, 0xD9],
          filename: 'engine.jpg',
          contentType: 'image/jpeg',
          fields: const {'category': 'Engine', 'notes': ' heavy-duty'},
        ),
      ),
    );
    expect(response.statusCode, 200);
    expect(response.body, {'ok': true});
  });

  test('supports top-level JSON list responses and 204 No Content responses',
      () async {
    final storage = MemoryCredentialStore()..pair = _activePair();
    final transport = CallbackTransport((request) async {
      if (request.uri.path == '/api/v1/products/pending') {
        return const ApiResponse(
          statusCode: 200,
          body: [
            {'id': 'p1', 'name': 'Brake Disc'},
            {'id': 'p2', 'name': 'Spark Plug'},
          ],
        );
      }
      if (request.uri.path == '/api/v1/empty-operation') {
        return const ApiResponse(statusCode: 204);
      }
      throw StateError('Unexpected request ${request.uri}');
    });

    final api =
        ApiClient(baseUrl: baseUrl, transport: transport, credentials: storage);
    final pending = await api.get('/api/v1/products/pending') as List<dynamic>;
    expect(pending, hasLength(2));

    final noContent = await api.post('/api/v1/empty-operation');
    expect(noContent, isNull);
  });

  test(
      'IoApiTransport rejects malformed 200 JSON and tolerates non-JSON error bodies',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((HttpRequest request) async {
      if (request.uri.path == '/malformed-200') {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write('<html>not valid json</html>');
        await request.response.close();
        return;
      }
      if (request.uri.path == '/html-502') {
        request.response
          ..statusCode = 502
          ..headers.contentType = ContentType.html
          ..write('<html>Bad Gateway</html>');
        await request.response.close();
        return;
      }
      request.response.statusCode = 404;
      await request.response.close();
    });

    final transport = IoApiTransport();
    addTearDown(() => transport.close(force: true));
    final serverUri = Uri.parse('http://${server.address.host}:${server.port}');

    await expectLater(
      transport.send(
        ApiRequest(method: 'GET', uri: serverUri.resolve('/malformed-200')),
      ),
      throwsA(isA<FormatException>()),
    );

    final errorResponse = await transport.send(
      ApiRequest(method: 'GET', uri: serverUri.resolve('/html-502')),
    );
    expect(errorResponse.statusCode, 502);
    expect(errorResponse.body, isNull);
  });

  test(
      'IoApiTransport aborts request on pre-close failure, cleans up on response timeout, and closes cleanly',
      () async {
    final releaseStream = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      if (!releaseStream.isCompleted) {
        releaseStream.complete();
      }
      await server.close(force: true);
    });

    server.listen((HttpRequest request) async {
      if (request.uri.path == '/hang-body') {
        request.response.statusCode = 200;
        request.response.bufferOutput = false;
        request.response.add(const [0x7B]);
        await request.response.flush();
        await releaseStream.future;
        await request.response.close();
        return;
      }
      request.response
        ..statusCode = 200
        ..write('{}');
      await request.response.close();
    });

    final transport = IoApiTransport(
      responseTimeout: const Duration(milliseconds: 60),
    );
    addTearDown(() => transport.close(force: true));
    final serverUri = Uri.parse('http://${server.address.host}:${server.port}');

    // 1. Pre-close JSON encoding failure aborts the opened HttpClientRequest.
    await expectLater(
      transport.send(
        ApiRequest(
          method: 'POST',
          uri: serverUri.resolve('/ok'),
          body: {'unencodable': Object()},
        ),
      ),
      throwsA(isA<JsonUnsupportedObjectError>()),
    );

    // 2. Response stream timeout cancels subscription and detaches socket.
    await expectLater(
      transport.send(
        ApiRequest(method: 'GET', uri: serverUri.resolve('/hang-body')),
      ),
      throwsA(isA<TimeoutException>()),
    );

    // 3. Closing transport prevents further sends.
    transport.close(force: true);
    expect(transport.isClosed, isTrue);
    await expectLater(
      transport.send(
        ApiRequest(method: 'GET', uri: serverUri.resolve('/ok')),
      ),
      throwsA(isA<StateError>()),
    );
  });
}

class _HookedCredentialStore implements CredentialStore {
  _HookedCredentialStore({
    this.initial,
    required this.onRead,
    this.onClear,
  }) : pair = initial;

  final TokenPair? initial;
  final Future<void> Function() onRead;
  final Future<void> Function()? onClear;
  TokenPair? pair;

  @override
  Future<TokenPair?> read() async {
    await onRead();
    return pair;
  }

  @override
  Future<void> write(TokenPair value) async {
    pair = value;
  }

  @override
  Future<void> clear() async {
    pair = null;
    await onClear?.call();
  }
}
