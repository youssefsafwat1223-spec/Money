import 'dart:ui';

import 'package:another_telephony/telephony.dart';
import 'package:flutter/widgets.dart';

import 'services/captured_message_processor.dart';

@pragma('vm:entry-point')
Future<void> handleIncomingSmsInBackground(SmsMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final body = message.body?.trim();
  if (body == null || body.isEmpty) {
    return;
  }

  await CapturedMessageProcessor.process(
    rawMessage: body,
    senderId: message.address,
  );
}
