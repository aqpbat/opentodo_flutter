// One operation of the field-level op log (docs/sync.md). The wire format is
// plain JSON; `value` keeps its decoded JSON shape (string, number, boolean,
// null, List, Map).

import 'hlc.dart';

class Op {
  String id;
  String entity;
  String entityId;
  String field;
  Object? value;
  int ts;
  String device;

  /// Served ops only: the author's account id (ignored on input).
  String? actor;

  Op({
    required this.id,
    required this.entity,
    required this.entityId,
    required this.field,
    required this.value,
    required this.ts,
    required this.device,
    this.actor,
  });

  factory Op.fromJson(Map<String, dynamic> j) => Op(
        id: j['id'] as String,
        entity: j['entity'] as String,
        entityId: j['entityId'] as String,
        field: j['field'] as String,
        value: j['value'],
        ts: (j['ts'] as num).toInt(),
        device: j['device'] as String,
        actor: j['actor'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'entity': entity,
        'entityId': entityId,
        'field': field,
        'value': value,
        'ts': ts,
        'device': device,
      };

  /// Whether this op beats the stored clock of the same field.
  bool beats(int? storedTs, String? storedDevice) =>
      wins(ts, device, existingTs: storedTs, existingDevice: storedDevice);

  @override
  String toString() => 'Op($entity/$entityId.$field ts=$ts device=$device)';
}
