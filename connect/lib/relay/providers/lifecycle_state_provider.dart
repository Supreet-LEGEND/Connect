import 'dart:ui' show AppLifecycleState;
import 'package:flutter_riverpod/legacy.dart';

final lifeCycleStateProvider = StateProvider.autoDispose<AppLifecycleState>((
  ref,
) {
  return AppLifecycleState.resumed;
});
