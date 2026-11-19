// The address rules and the health check of the first-run screen, ported
// from mobile/ios/OpenTodo/ServerAddress.swift and HealthCheck.swift
// (mobile/README.md, "How it fits together"): https anywhere; plain http only
// for this device, the local network and `.local` names, accepted after a
// warning; `GET /api/v1/health`, then `/healthz`, with the failure named.

import 'dart:io' show TlsException;

import '../data/api.dart';

/// The result of [ServerAddress.parse].
sealed class ServerAddress {
  const ServerAddress();

  /// Parses what was typed into the address field. No scheme means https.
  static ServerAddress parse(String input) {
    var text = input.trim();
    if (text.isEmpty || text.contains(RegExp(r'\s'))) return const InvalidAddress();
    if (!text.contains('://')) text = 'https://$text';
    // Unicode hosts would need Punycode (ServerAddress.swift asciiHost);
    // not supported yet.
    if (text.codeUnits.any((c) => c > 0x7f)) return const InvalidAddress();
    final uri = Uri.tryParse(text);
    if (uri == null) return const InvalidAddress();
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') return const InvalidAddress();
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      return const InvalidAddress();
    }
    if (uri.path.isNotEmpty && uri.path != '/') return const InvalidAddress();
    final host = _normaliseHost(uri.host);
    if (host.isEmpty) return const InvalidAddress();
    final int? port = uri.hasPort ? uri.port : null;
    if (port != null && (port < 1 || port > 65535)) return const InvalidAddress();

    final hostPart = host.contains(':') ? '[$host]' : host;
    final defaultPort = scheme == 'https' ? 443 : 80;
    final suffix = port == null || port == defaultPort ? '' : ':$port';
    final origin = '$scheme://$hostPart$suffix';
    if (scheme == 'https') return ValidAddress(origin, insecure: false);
    if (isLocal(host)) return ValidAddress(origin, insecure: true);
    final httpsPort = port == null || port == 80 ? '' : ':$port';
    return NeedsHttps('https://$hostPart$httpsPort');
  }

  /// This device, private IPv4 ranges, IPv6 loopback, unique-local and
  /// link-local, and `.local` names.
  static bool isLocal(String rawHost) {
    final host = _normaliseHost(rawHost);
    if (host == 'localhost' || host.endsWith('.localhost') || host.endsWith('.local')) {
      return true;
    }
    final v4 = host.split('.');
    if (v4.length == 4 &&
        v4.every((p) => RegExp(r'^\d{1,3}$').hasMatch(p) && int.parse(p) <= 255)) {
      final a = int.parse(v4[0]), b = int.parse(v4[1]);
      return a == 127 ||
          a == 10 ||
          (a == 172 && b >= 16 && b <= 31) ||
          (a == 192 && b == 168) ||
          (a == 169 && b == 254);
    }
    if (host.contains(':')) {
      return host == '::1' ||
          const ['fc', 'fd', 'fe8', 'fe9', 'fea', 'feb'].any(host.startsWith);
    }
    return false;
  }

  /// Lowercase, no trailing dot, no IPv6 brackets.
  static String _normaliseHost(String raw) {
    var host = raw.toLowerCase();
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    if (host.endsWith('.')) host = host.substring(0, host.length - 1);
    return host;
  }
}

/// A usable origin such as `https://todo.example.com` or
/// `http://192.168.1.4:8080`; [insecure] for plain http (local only).
class ValidAddress extends ServerAddress {
  final String origin;
  final bool insecure;
  const ValidAddress(this.origin, {required this.insecure});
}

/// Plain http to a public name: refused, with the https address to offer.
class NeedsHttps extends ServerAddress {
  final String suggestion;
  const NeedsHttps(this.suggestion);
}

class InvalidAddress extends ServerAddress {
  const InvalidAddress();
}

// ---- health check ----

/// Why the health check failed (HealthCheck.swift `Outcome`).
enum HealthProblem {
  /// No answer: no network, unknown host, refused, timed out.
  noNetwork,

  /// Something answered, but not OpenTodo's health route.
  notOpenTodo,

  /// The TLS certificate was refused; never bypassed.
  untrusted,
}

class HealthCheckFailed implements Exception {
  final HealthProblem problem;
  const HealthCheckFailed(this.problem);

  @override
  String toString() => 'HealthCheckFailed($problem)';
}

/// Asks the server at an origin for its health; throws [HealthCheckFailed]
/// naming the failure.
typedef HealthCheck = Future<HealthInfo> Function(String origin);

/// The app's health check: one try, ten seconds. [ApiClient.health] already
/// falls back to `/healthz` for servers before 1.0.1.
Future<HealthInfo> checkServerHealth(String origin,
    {ApiClient Function(String origin)? api}) async {
  final client = api != null
      ? api(origin)
      : ApiClient(origin, maxAttempts: 1, timeout: const Duration(seconds: 10));
  final HealthInfo info;
  try {
    info = await client.health();
  } catch (e) {
    throw HealthCheckFailed(classifyHealthError(e));
  }
  if (info.status != 'ok') throw const HealthCheckFailed(HealthProblem.notOpenTodo);
  return info;
}

/// Certificate problems apart from everything else: a wrong server versus an
/// unreachable one.
HealthProblem classifyHealthError(Object error) {
  if (error is HealthCheckFailed) return error.problem;
  if (error is NetworkError) {
    return error.cause is TlsException ? HealthProblem.untrusted : HealthProblem.noNetwork;
  }
  if (error is TlsException) return HealthProblem.untrusted;
  // An error status, non-JSON or JSON of another shape.
  return HealthProblem.notOpenTodo;
}
