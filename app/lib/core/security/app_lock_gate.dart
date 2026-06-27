import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';
import '../utils/app_lucide_icons.dart';
import 'app_lock_service.dart';

class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  bool _checking = true;
  bool _locked = false;
  bool _authenticating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _lockIfNeeded());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _locked = true;
      return;
    }
    if (state == AppLifecycleState.resumed) {
      _lockIfNeeded();
    }
  }

  Future<void> _lockIfNeeded() async {
    if (_authenticating || !mounted) return;
    final enabled = await AppLockService.instance.isEnabled();
    if (!mounted) return;
    if (!enabled) {
      setState(() {
        _checking = false;
        _locked = false;
      });
      return;
    }
    setState(() {
      _checking = false;
      _locked = true;
    });
    await _unlock();
  }

  Future<void> _unlock() async {
    if (_authenticating || !mounted) return;
    setState(() => _authenticating = true);
    HapticFeedback.selectionClick();
    final ok = await AppLockService.instance.authenticate();
    if (!mounted) return;
    setState(() {
      _authenticating = false;
      _locked = !ok;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_checking && !_locked) return widget.child;
    return _LockScreen(
      authenticating: _authenticating || _checking,
      onUnlock: _unlock,
    );
  }
}

class _LockScreen extends StatelessWidget {
  const _LockScreen({
    required this.authenticating,
    required this.onUnlock,
  });

  final bool authenticating;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: c.bg,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.gutter),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      color: c.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: c.primary.withValues(alpha: 0.22),
                      ),
                    ),
                    child: Icon(
                      AppLucideIcons.wallet,
                      color: c.primary,
                      size: 34,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s5),
                  Text(
                    'قرش مقفول',
                    style: AppTypography.headline(c.textMain),
                  ),
                  const SizedBox(height: AppSpacing.s2),
                  Text(
                    'افتح التطبيق للتحقق من هويتك وعرض بياناتك المالية.',
                    textAlign: TextAlign.center,
                    style: AppTypography.callout(c.textLight),
                  ),
                  const SizedBox(height: AppSpacing.s5),
                  FilledButton.icon(
                    onPressed: authenticating ? null : onUnlock,
                    icon: authenticating
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.lock_open_rounded),
                    label: Text(authenticating ? 'جاري التحقق...' : 'فتح قرش'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      backgroundColor: c.primary,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
