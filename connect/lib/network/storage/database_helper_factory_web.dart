import 'package:connect/network/storage/database_helper.dart';
import 'package:connect/network/storage/database_helper_web.dart';

void initializeDatabaseHelper() {
  DatabaseHelper.initialize(DatabaseHelperWeb.instance);
}