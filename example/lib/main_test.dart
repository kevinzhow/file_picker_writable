// Driver is a dev dependency of the example package only.
// ignore: depend_on_referenced_packages
import 'package:flutter_driver/driver_extension.dart';

import 'main.dart' as app;

Future<void> main() async {
  enableFlutterDriverExtension();
  await app.main();
}
