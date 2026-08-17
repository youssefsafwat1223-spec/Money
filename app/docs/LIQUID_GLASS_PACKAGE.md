# liquid_glass_renderer — adoption note

- **Status**: prerelease, pinned EXACTLY to `0.2.0-dev.4` in pubspec (a `^dev`
  range could silently pull a materially different dev build).
- **Boundary**: wrapped behind `MaliGlass`; the only files allowed to import
  the package are `lib/core/theme/widgets/mali_glass_advanced.dart` and the
  design gallery. Enforced by `test/core/theme/widgets/glass_import_guard_test.dart`.
- **Scope**: advanced shader tier on the pilot surfaces only (Flutter fallback
  bottom nav + Transactions pinned-strip capsules). Native iOS 26 nav,
  high-contrast, reduce-motion, tokens, and fallback policy stay Qirsh-owned.
  `Glassify` is banned from production (experimental; SkSL precompile error
  observed 2026-08-17).
- **Updating**: bump deliberately → run the /design A/B gallery + MaliGlass
  suite, re-check visuals and performance, and RE-VERIFY ANDROID on a real
  mid-range device (upstream has open Android rendering issues: #85 #123 #140
  #141 #149 at review time).
- **Production gate**: real-Android-device validation still PENDING; until it
  passes, the package must not expand beyond the pilot surfaces.
