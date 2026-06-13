class AndroidSmsCaptureService {
  AndroidSmsCaptureService._();

  static final AndroidSmsCaptureService instance = AndroidSmsCaptureService._();

  Future<bool> requestPermissions() async {
    return false;
  }

  Future<void> startListeningIfPermitted({bool forceRestart = false}) async {
    return;
  }
}
