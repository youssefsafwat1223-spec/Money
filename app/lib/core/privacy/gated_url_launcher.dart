import 'package:url_launcher/url_launcher.dart';

import 'cloud_egress_gate.dart';

/// Astra H2.5: the ONE way the app opens an external URL. Every `url_launcher`
/// call site goes through it (a source-scan test pins that no other file imports
/// `url_launcher`). While the egress gate does not permit (Cloud OFF, unset,
/// unresolved, DISABLING, uncertain) the launch is DENIED and this returns
/// `false`, which every call site already treats as "could not open". The only
/// exception is an allowlisted host inside an active account-control grant
/// ([CloudEgressGate.mayLaunchExternal]); no call site needs it today.
Future<bool> launchExternalUrl(Uri uri) async {
  if (!await CloudEgressGate.instance.mayLaunchExternal(uri)) return false;
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
