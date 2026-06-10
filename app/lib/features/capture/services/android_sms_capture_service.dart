import 'dart:io';

import 'package:another_telephony/telephony.dart';

import '../capture_runtime.dart';
import '../sms_background_handler.dart';
import 'captured_message_processor.dart';
import 'local_notification_service.dart';
import 'native_capture_bridge.dart';

class AndroidSmsCaptureService {
  AndroidSmsCaptureService._();

  static final AndroidSmsCaptureService instance = AndroidSmsCaptureService._();

  final Telephony _telephony = Telephony.instance;
  bool _listening = false;

  Future<bool> requestPermissions() async {
    if (!Platform.isAndroid) {
      return false;
    }
    await LocalNotificationService.instance.requestPermissionsIfNeeded();
    final granted = await _telephony.requestPhoneAndSmsPermissions ?? false;
    if (granted) {
      await startListeningIfPermitted(forceRestart: true);
    }
    return granted;
  }

  Future<void> startListeningIfPermitted({bool forceRestart = false}) async {
    if (!Platform.isAndroid) {
      return;
    }
    if (_listening && !forceRestart) {
      return;
    }
    final granted = await NativeCaptureBridge.hasSmsPermission();
    if (!granted) {
      _listening = false;
      return;
    }

    _telephony.listenIncomingSms(
      onNewMessage: _onForegroundMessage,
      onBackgroundMessage: handleIncomingSmsInBackground,
      listenInBackground: true,
    );
    _listening = true;
  }

  Future<void> _onForegroundMessage(SmsMessage message) async {
    final body = message.body?.trim();
    if (body == null || body.isEmpty) {
      return;
    }

    final result = await CapturedMessageProcessor.process(
      rawMessage: body,
      senderId: message.address,
      showNotifications: false,
    );
    if (result.addTransactionResult.requiresConfirmation &&
        result.transactionId != null) {
      CaptureRuntime.instance.requestConfirmation(result.transactionId!);
    }
  }
}
