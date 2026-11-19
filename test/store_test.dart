import 'package:flutter_test/flutter_test.dart';
import 'package:opentodo_flutter/data/store.dart';

import 'store_contract.dart';

void main() {
  group('MemoryStore', () => runSyncStoreContract(() async => MemoryStore()));
}
