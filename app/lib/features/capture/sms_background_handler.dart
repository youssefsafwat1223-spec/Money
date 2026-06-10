import 'dart:ui';

import 'package:another_telephony/telephony.dart';
import 'package:flutter/widgets.dart';

import '../../engine/parser/bank_sender_filter.dart';
import 'services/captured_message_processor.dart';

@pragma('vm:entry-point')
Future<void> handleIncomingSmsInBackground(SmsMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final body = message.body?.trim();
  if (body == null || body.isEmpty) {
    return;
  }

  // نقرأ من البنوك فقط — نتجاهل الرسائل الشخصية.
  if (!BankSenderFilter.isLikelyBank(message.address, text: body)) {
    return;
  }

  await CapturedMessageProcessor.process(
    rawMessage: body,
    senderId: message.address,
  );
}
