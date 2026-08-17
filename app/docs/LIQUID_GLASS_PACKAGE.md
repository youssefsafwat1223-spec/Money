# liquid_glass_renderer — adoption note

**Status: `PACKAGE_ADAPTER_ACCEPTED` ·
`ANDROID_ADVANCED_REFRACTION_DISABLED_PENDING_DEVICE_GATE`**

The adapter architecture is accepted and the dependency is in, behind
`MaliGlass`. Android production surfaces resolve to Qirsh frost regardless of
shader support (`kAndroidAdvancedRefractionEnabled = false` in
`mali_glass_advanced.dart`) — a temporary rollout hold, **not a package
rejection**. Native tier scope: generic `MaliGlass` never self-selects the
native platform view; native UIGlassEffect belongs only to the pre-existing
iOS 26 bottom-navigation host.

**Required evidence before enabling the Android advanced tier** (then flip the
flag): real mid-range Android device · shader/renderer capability status ·
first-render check · fast Transactions scroll · tab navigation · app
resume/background · light/dark · RTL · meaningful frame/performance
observation.

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
