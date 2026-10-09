import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_config.dart';

/// The SDK client used at the shell's authentication boundary.
final authClientProvider = Provider<SupabaseClient?>(
    (ref) => SupabaseConfig.isConfigured ? Supabase.instance.client : null);
