import 'package:flutter_local_notifications/flutter_local_notifications.dart';

void main() {
  final plugin = FlutterLocalNotificationsPlugin();
  plugin.show(
    id: 99001,
    title: 'Test',
    body: 'Test',
  );
}
