import 'catalog_daos.dart';

class AnnouncementService {
  AnnouncementService({required RemoteAnnouncementsDao dao}) : _dao = dao;

  final RemoteAnnouncementsDao _dao;

  Future<List<RemoteAnnouncement>> getActiveAnnouncements() =>
      _dao.getActiveNonDismissed();

  Future<void> dismiss(String id) => _dao.setDismissed(id);

  /// Returns true if any active non-dismissed announcement has
  /// severity == 'force_update'. This blocks all app navigation.
  Future<bool> hasForceUpdate() async {
    final announcements = await _dao.getActiveNonDismissed();
    return announcements.any((a) => a.isForceUpdate);
  }
}
