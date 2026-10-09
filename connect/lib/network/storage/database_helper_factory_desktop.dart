import 'package:connect/network/storage/database_helper.dart';
import 'package:connect/network/storage/database_helper_desktop.dart';

void initializeDatabaseHelper() {
  DatabaseHelper.initialize(DatabaseHelperDesktop.instance);
}