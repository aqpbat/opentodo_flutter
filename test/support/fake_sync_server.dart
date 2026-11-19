// An in-memory model of the server's op log for sync tests (docs/sync.md
// §Exchange, §Paging, §Log generation; internal/sync Apply/Pull): ops are
// stored once per id, the winner rule picks field values, a pull skips the
// caller's own ops but advances the cursor past them, pages hold at most
// [pageLimit] ops, and a restore cuts the log and changes the generation.

import 'package:opentodo_flutter/core/hlc.dart';
import 'package:opentodo_flutter/core/op.dart';

class FakeSyncServer {
  final List<(int, Op)> log = [];
  final Map<String, Op> winners = {};
  final Set<String> _ids = {};
  int _seq = 0;
  String generation = 'gen-1';
  int pageLimit = 1000;

  /// The server's clock (ms).
  int now = 1800000000000;

  /// A refusal reason for an op, or null to accept it (clock skew is checked
  /// separately).
  String? Function(Op op)? refuse;

  /// Exchanges served, for assertions.
  final List<Map<String, dynamic>> requests = [];
  final List<Map<String, dynamic>> responses = [];
  int duplicates = 0;

  static String key(Op o) => '${o.entity}\u0000${o.entityId}\u0000${o.field}';

  Object? value(String entity, String id, String field) => winners['$entity\u0000$id\u0000$field']?.value;

  Future<Map<String, dynamic>> exchange(Map<String, dynamic> body) async {
    requests.add(body);
    final device = body['device'] as String;
    var cursor = (body['cursor'] as num).toInt();
    final features = (body['features'] as List).cast<String>();
    final rejected = <Map<String, dynamic>>[];
    final refusedKeys = <String>{};
    var applied = 0;
    for (final j in body['ops'] as List) {
      final op = Op.fromJson((j as Map).cast<String, dynamic>());
      if (features.contains('clock_skew') && op.ts > now + maxFutureSkewMs) {
        rejected.add({'id': op.id, 'reason': 'clock_skew', 'serverTime': now});
        continue;
      }
      final reason = refuse?.call(op);
      if (reason != null) {
        rejected.add({'id': op.id, 'reason': reason});
        refusedKeys.add(key(op));
        continue;
      }
      if (!_ids.add(op.id)) {
        duplicates++;
        continue;
      }
      log.add((++_seq, op));
      final cur = winners[key(op)];
      if (op.beats(cur?.ts, cur?.device)) winners[key(op)] = op;
      applied++;
    }
    final served = <Op>[];
    var hasMore = false;
    for (final (seq, op) in log) {
      if (seq <= cursor) continue;
      if (served.length == pageLimit) {
        hasMore = true;
        break;
      }
      cursor = seq;
      if (op.device == device) continue;
      served.add(op);
    }
    // The current winner of every refused field, so the device takes it.
    for (final k in refusedKeys) {
      final w = winners[k];
      if (w != null) served.add(w);
    }
    final res = <String, dynamic>{
      'applied': applied,
      'duplicates': 0,
      'ops': [for (final o in served) o.toJson()],
      'cursor': cursor,
      'hasMore': hasMore,
      'serverTime': now,
      'generation': generation,
      'rejected': rejected,
    };
    responses.add(res);
    return res;
  }

  /// A restore from a backup taken at [seq]: later ops are gone and the
  /// generation changes.
  void restore(int seq) {
    log.removeWhere((e) => e.$1 > seq);
    _seq = seq;
    _ids
      ..clear()
      ..addAll(log.map((e) => e.$2.id));
    winners.clear();
    for (final (_, op) in log) {
      final cur = winners[key(op)];
      if (op.beats(cur?.ts, cur?.device)) winners[key(op)] = op;
    }
    generation = 'gen-${DateTime.now().microsecondsSinceEpoch}';
  }

  int get head => _seq;
}
