import 'package:connect/network/storage/database_helper.dart';
import 'package:connect/network/storage/database_helper_impl.dart';

void initializeDatabaseHelper() {
  DatabaseHelper.initialize(DatabaseHelperMobile.instance);
}