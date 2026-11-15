import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

enum ApiResponseType { json, bytes }

class MultipartFilePayload {
  MultipartFilePayload({
    required List<int> bytes,
    required this.filename,
    required this.contentType,
    this.fieldName = 'file',
    Map<String, String> fields = const {},
  })  : _bytes = Uint8List.fromList(bytes),
        fields = Map.unmodifiable(fields) {
    if (_bytes.isEmpty) {
      throw ArgumentError.value(
        bytes,
        'bytes',
        'Multipart file bytes must not be empty.',
      );
    }
    if (filename.trim().isEmpty) {
      throw ArgumentError.value(
        filename,
        'filename',
        'Filename must not be empty.',
      );
    }
    if (contentType.trim().isEmpty) {
      throw ArgumentError.value(
        contentType,
        'contentType',
        'Content type must not be empty.',
      );
    }
    if (fieldName.trim().isEmpty) {
      throw ArgumentError.value(
        fieldName,
        'fieldName',
        'Field name must not be empty.',
      );
    }
  }

  final Uint8List _bytes;
  final String filename;
  final String contentType;
  final String fieldName;
  final Map<String, String> fields;

  Uint8List get bytes => Uint8List.fromList(_bytes);
}

class ApiRequest {
  const ApiRequest({
    required this.method,
    required this.uri,
    this.headers = const {},
    this.body,
    this.responseType = ApiResponseType.json,
  });
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Object? body;
  final ApiResponseType responseType;
}

class ApiResponse {
  const ApiResponse({
    required this.statusCode,
    this.body,
    this.headers = const {},
  });
  final int statusCode;
  final Object? body;
  final Map<String, String> headers;
}

abstract interface class ApiTransport {
  Future<ApiResponse> send(ApiRequest request);
  void close({bool force = false});
}

class IoApiTransport implements ApiTransport {
  IoApiTransport({
    HttpClient? client,
    this.requestTimeout = const Duration(seconds: 20),
    this.responseTimeout = const Duration(seconds: 20),
  }) : _client = client ?? HttpClient();

  final HttpClient _client;
  final Duration requestTimeout;
  final Duration responseTimeout;
  bool _isClosed = false;
  static const _boundary = '----BmmAutoMotorsBoundary7MA4YWxkTrZu0gW';

  bool get isClosed => _isClosed;

  @override
  void close({bool force = false}) {
    if (_isClosed) return;
    _isClosed = true;
    _client.close(force: force);
  }

  @override
  Future<ApiResponse> send(ApiRequest request) async {
    if (_isClosed) {
      throw StateError('Cannot send a request on a closed IoApiTransport.');
    }
    final httpRequest =
        await _client.openUrl(request.method, request.uri).timeout(
              requestTimeout,
            );
    final HttpClientResponse response;
    try {
      httpRequest.followRedirects = false;
      request.headers.forEach(httpRequest.headers.set);
      final requestBody = request.body;
      if (requestBody is MultipartFilePayload) {
        final multipartBytes = _encodeMultipart(requestBody);
        httpRequest.headers.set(
          HttpHeaders.contentTypeHeader,
          'multipart/form-data; boundary=$_boundary',
        );
        httpRequest.contentLength = multipartBytes.length;
        httpRequest.add(multipartBytes);
      } else if (requestBody != null) {
        final encodedJson = utf8.encode(jsonEncode(requestBody));
        httpRequest.headers.contentType = ContentType.json;
        httpRequest.contentLength = encodedJson.length;
        httpRequest.add(encodedJson);
      }
      response = await httpRequest.close().timeout(requestTimeout);
    } on Object {
      httpRequest.abort();
      rethrow;
    }

    final responseBytes = await _readResponseBytes(response);
    final responseHeaders = <String, String>{};
    response.headers.forEach((name, values) {
      if (values.isNotEmpty) {
        responseHeaders[name.toLowerCase()] = values.join(', ');
      }
    });

    if (request.responseType == ApiResponseType.bytes &&
        response.statusCode >= 200 &&
        response.statusCode < 300) {
      return ApiResponse(
        statusCode: response.statusCode,
        body: responseBytes,
        headers: responseHeaders,
      );
    }

    Object? body;
    if (responseBytes.isNotEmpty) {
      try {
        final text = utf8.decode(responseBytes);
        if (text.isNotEmpty) {
          body = jsonDecode(text);
        }
      } on FormatException {
        if (response.statusCode >= 200 && response.statusCode < 300) {
          rethrow;
        }
        body = null;
      }
    }
    return ApiResponse(
      statusCode: response.statusCode,
      body: body,
      headers: responseHeaders,
    );
  }

  Future<Uint8List> _readResponseBytes(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    final completer = Completer<Uint8List>();
    late final StreamSubscription<List<int>> subscription;
    subscription = response.listen(
      builder.add,
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(builder.takeBytes());
        }
      },
      cancelOnError: true,
    );
    try {
      return await completer.future.timeout(responseTimeout);
    } on Object {
      await subscription.cancel();
      try {
        final socket = await response.detachSocket();
        socket.destroy();
      } on Object {
        // Socket may already be closed or not detachable on custom responses.
      }
      rethrow;
    }
  }

  static Uint8List _encodeMultipart(MultipartFilePayload payload) {
    final builder = BytesBuilder(copy: false);
    void writeAscii(String value) => builder.add(utf8.encode(value));

    for (final entry in payload.fields.entries) {
      writeAscii('--$_boundary\r\n');
      writeAscii(
        'Content-Disposition: form-data; name="${_escapeHeader(entry.key)}"\r\n\r\n',
      );
      writeAscii('${entry.value}\r\n');
    }

    writeAscii('--$_boundary\r\n');
    writeAscii(
      'Content-Disposition: form-data; '
      'name="${_escapeHeader(payload.fieldName)}"; '
      'filename="${_escapeHeader(payload.filename)}"\r\n',
    );
    writeAscii('Content-Type: ${_escapeHeader(payload.contentType)}\r\n\r\n');
    builder.add(payload.bytes);
    writeAscii('\r\n--$_boundary--\r\n');
    return builder.takeBytes();
  }

  static String _escapeHeader(String value) =>
      value.replaceAll('\r', '').replaceAll('\n', '').replaceAll('"', r'\"');
}
