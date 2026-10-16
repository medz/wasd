// Generated from test/fixtures/host_exceptions/*.wat with wasm-tools 1.254.0.
import 'dart:convert';
import 'dart:typed_data';

Uint8List hostExceptionFixture(String name) => base64Decode(_fixtures[name]!);

const _fixtures = <String, String>{
  'f32_bits':
      'AGFzbQEAAAABEQRgAABgAX0AYAACfWlgAAF/AicDBGhvc3QEdGljawAABGhvc3QGc291cmNlAAAEaG9zdAN0YWcEAAEDAwIAAwcWAgV0aHJvdwACCmNhdGNoX2JpdHMAAwo1AiABAWkCAh9AAQEAABAAQcXGhP4HvggACwALIQAaIAAKCxIAAn0fQAEAAAAQABABCwALvAsAQQRuYW1lAQ8CAAR0aWNrAQZzb3VyY2UCCgECAQAFZXJyb3IDFQICAQAGY2F1Z2h0AwEABmNhdWdodAsGAQADdGFn',
  'host_start':
      'AGFzbQEAAAABBAFgAAACDQEEaG9zdAR0aWNrAAADAgEACAEBCgYBBAAQAAsAFQRuYW1lAQ4CAAR0aWNrAQVzdGFydA==',
  'mixed_throw':
      'AGFzbQEAAAABCwJgAABgBH9+fXwAAg0BBGhvc3QEdGljawAAAwIBAQ0DAQABBxcDA3RhZwQABWFsaWFzBAAFdGhyb3cAAQoQAQ4AEAAgACABIAIgAwgACwAWBG5hbWUBBwEABHRpY2sLBgEAA3RhZw==',
  'start':
      'AGFzbQEAAAABCAJgAX8AYAAAAg0BBGhvc3QDdGFnBAAAAwIBAQgBAAoIAQYAQRMIAAsAFwRuYW1lAQgBAAVzdGFydAsGAQADdGFn',
};
