# MALI — Icon Pack

Brand assets for the Mali (مالي) expense tracking app.

## Color palette

| Color | Hex | Usage |
|-------|-----|-------|
| Green Dark  | `#005F3D` | Symbol on light backgrounds |
| Green Light | `#09A568` | Symbol on dark backgrounds |
| Orange      | `#F9AA0F` | Pommel dot (accent) |
| Navy        | `#0C273F` | Dark theme background |
| White       | `#FFFFFF` | Light theme background |

## Folder structure

```
output/
├─ master_1024/                  ← high-res master PNGs (1024×1024)
│   ├─ app_icon_light.png        ← App launcher icon (light bg)
│   ├─ app_icon_dark.png         ← App launcher icon (dark bg)
│   ├─ branding_light.png        ← With MALI + مالي text (splash)
│   ├─ branding_dark.png
│   ├─ symbol_green_dark.png     ← Transparent symbol (dark green)
│   └─ symbol_green_light.png    ← Transparent symbol (light green)
│
├─ ios_AppIcon.appiconset/       ← Drop into ios/Runner/Assets.xcassets/
│   ├─ Contents.json
│   └─ Icon-App-*.png            ← All 15 iOS sizes
│
├─ android_res/                  ← Drop into android/app/src/main/res/
│   ├─ mipmap-mdpi/ ic_launcher.png + ic_launcher_foreground.png
│   ├─ mipmap-hdpi/   ...
│   ├─ mipmap-xhdpi/  ...
│   ├─ mipmap-xxhdpi/ ...
│   ├─ mipmap-xxxhdpi/ ...
│   ├─ mipmap-anydpi-v26/ ic_launcher.xml  ← adaptive icon
│   ├─ values/ic_launcher_background.xml
│   └─ playstore_icon_512.png   ← For Google Play listing
│
├─ inapp_assets/                 ← Drop into your Flutter assets/ folder
│   ├─ mali_symbol_green_dark.svg     ← Use with flutter_svg (recommended)
│   ├─ mali_symbol_green_light.svg
│   └─ mali_{green_dark|green_light}_{24|48|96|192}{,@2x,@3x}.png
│
├─ flutter_launcher_icons.yaml   ← Auto-generation config
├─ PREVIEW_summary.png           ← Visual overview
└─ README.md
```

## How to use

### Option A — Auto-generate everything (easiest)

```bash
# 1. Create assets/icon/ in your Flutter project
mkdir -p assets/icon

# 2. Copy the master file as your app icon
cp master_1024/app_icon_light.png assets/icon/app_icon.png

# 3. For adaptive icon foreground, use the transparent symbol
cp master_1024/symbol_green_dark.png assets/icon/app_icon_foreground.png

# 4. Install the package
flutter pub add --dev flutter_launcher_icons

# 5. Copy the YAML to your project root (or merge into pubspec.yaml)
cp flutter_launcher_icons.yaml .

# 6. Generate
dart run flutter_launcher_icons
```

### Option B — Manual drop-in (faster, no extra package)

**iOS:**
```bash
cp -r ios_AppIcon.appiconset/* ios/Runner/Assets.xcassets/AppIcon.appiconset/
```

**Android:**
```bash
cp -r android_res/* android/app/src/main/res/
```

### Using the symbol inside the app

Add to `pubspec.yaml`:
```yaml
dependencies:
  flutter_svg: ^2.0.0

flutter:
  assets:
    - assets/icons/mali_symbol_green_dark.svg
    - assets/icons/mali_symbol_green_light.svg
```

In your widget code:
```dart
import 'package:flutter_svg/flutter_svg.dart';

// Adapts to theme
SvgPicture.asset(
  Theme.of(context).brightness == Brightness.dark
    ? 'assets/icons/mali_symbol_green_light.svg'
    : 'assets/icons/mali_symbol_green_dark.svg',
  width: 48,
  height: 48,
)
```

### Splash screen

Use `flutter_native_splash` with `master_1024/branding_light.png` (and `branding_dark.png` for dark mode).

```yaml
flutter_native_splash:
  color: "#FFFFFF"
  image: "master_1024/branding_light.png"
  color_dark: "#0C273F"
  image_dark: "master_1024/branding_dark.png"
  android_12:
    color: "#FFFFFF"
    image: "master_1024/symbol_green_dark.png"
    color_dark: "#0C273F"
    image_dark: "master_1024/symbol_green_light.png"
```

## Notes

- **App store guidelines**: Apple and Google recommend NOT including the app name in the launcher icon (the OS displays it below). So `app_icon_*.png` (symbol only) is what you submit. `branding_*.png` (with text) is for splash screens / inside-app branding only.
- **Adaptive icons (Android 8+)**: The foreground symbol is scaled to 60% to stay inside the safe zone, so different OEM masks (circle/squircle/rounded square) won't crop the design.
- **SVG over PNG**: For in-app icons, always prefer the SVG via `flutter_svg` — it scales to any size without loss.
