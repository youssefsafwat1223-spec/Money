import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../engine/parser/payment_aggregators.dart';

/// علامة العلامة التجارية (Brand mark).
///
/// الأولوية لشعار SVG حقيقي لو متوفّر في `assets/brands/`، وإلا مربّع ملوّن بحرف
/// مميّز للعلامات المعروفة، وبديل افتراضي لأي متجر — كله بدون أي طلب شبكة
/// (offline + خصوصية: مابنبعتش اسم التاجر لأي خدمة خارجية).
class BrandMark extends StatelessWidget {
  const BrandMark({
    super.key,
    required this.name,
    this.size = 44,
    this.logoUrl,
  });

  final String name;
  final double size;

  /// Admin-managed brand logo URL (from the synced catalog). When present it's
  /// shown first; on load failure it falls back to the bundled SVG / letter mark.
  final String? logoUrl;

  /// علامات لها شعار SVG حقيقي مرفق في الحزمة (assets/brands/<slug>.svg).
  /// عشان تزوّد علامة: حط ملف الـ SVG في assets/brands/ وأضِف سطر هنا.
  // ملاحظة: الترتيب مهم — المفتاح الأطول/الأخص قبل الأعم (UBER EATS قبل UBER)
  // لأن build بترجّع أول تطابق بالاحتواء.
  static const Map<String, String> _brandSvgs = {
    'NETFLIX': 'netflix',
    'SPOTIFY': 'spotify',
    'YOUTUBE': 'youtube',
    'APPLE MUSIC': 'applemusic',
    'APPLE TV': 'appletv',
    'APPLE': 'apple',
    'ICLOUD': 'apple',
    'STARBUCKS': 'starbucks',
    'MCDONALD': 'mcdonalds',
    'KFC': 'kfc',
    'UBER EATS': 'ubereats',
    'UBEREATS': 'ubereats',
    'UBER': 'uber',
    'DELIVEROO': 'deliveroo',
    'AIRBNB': 'airbnb',
    'CARREFOUR': 'carrefour',
    'IKEA': 'ikea',
    'VODAFONE': 'vodafone',
    'ORANGE': 'orange',
    'DEEZER': 'deezer',
    'CLAUDE': 'claude',
    'COPILOT': 'githubcopilot',
    'GITHUB': 'github',
    'TIDAL': 'tidal',
    'PARAMOUNT': 'paramountplus',
    'CRUNCHYROLL': 'crunchyroll',
    'HBO': 'hbomax',
  };

  static const Map<String, (Color, String)> _brands = {
    'NETFLIX': (Color(0xFFE50914), 'N'),
    'SPOTIFY': (Color(0xFF1DB954), 'S'),
    'SHAHID': (Color(0xFF00A19A), 'ش'),
    'شاهد': (Color(0xFF00A19A), 'ش'),
    'OSN': (Color(0xFF1A1A1A), 'O'),
    'ICLOUD': (Color(0xFF3B82F6), 'i'),
    'APPLE': (Color(0xFF1A1A1A), ''),
    'STC': (Color(0xFF4F008C), 'STC'),
    'MOBILY': (Color(0xFF00A551), 'M'),
    'ZAIN': (Color(0xFF6F2C91), 'Z'),
    'YOUTUBE': (Color(0xFFFF0000), 'Y'),
    'AMAZON': (Color(0xFFFF9900), 'a'),
    'STARBUCKS': (Color(0xFF00704A), 'S'),
  };

  /// كل ملفات SVG الموجودة فعلاً في assets/brands/ (slugs lowercase، الأطول
  /// أولاً للمطابقة الصحيحة). تُملأ مرة واحدة عند الإقلاع من AssetManifest، فأي
  /// SVG تضيفه للمجلد يشتغل تلقائياً بدون تعديل كود.
  static List<String> _assetSlugs = const [];

  static void registerAssetSlugs(Iterable<String> slugs) {
    _assetSlugs = slugs.map((s) => s.toLowerCase()).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
  }

  /// يحدّد slug الشعار المناسب لاسم التاجر: الأسماء الصريحة (متعددة الكلمات/
  /// القصيرة) أولاً، ثم مطابقة تلقائية مع الملفات المرفقة (≥4 أحرف لتفادي
  /// التطابقات الخاطئة).
  static String? _resolveSlug(String name) {
    // A bare payment gateway (e.g. "Fawry") is not the real merchant — never
    // show its logo; fall back to the category avatar.
    if (PaymentAggregators.isAggregator(name)) return null;
    final upper = name.toUpperCase();
    for (final entry in _brandSvgs.entries) {
      if (upper.contains(entry.key)) return entry.value;
    }
    final normalized = upper.replaceAll(RegExp('[^A-Z0-9]'), '');
    for (final slug in _assetSlugs) {
      if (slug.length >= 4 && normalized.contains(slug.toUpperCase())) {
        return slug;
      }
    }
    return null;
  }

  /// يرجّع رابط شعار العلامة من خريطة (keyword عريض → URL) اللي بتيجي من الـ
  /// admin/DB، بمطابقة اسم التاجر بالاحتواء. null لو مفيش تطابق.
  static String? logoFor(String name, Map<String, String> logos) {
    if (logos.isEmpty) return null;
    final upper = name.toUpperCase();
    for (final entry in logos.entries) {
      if (upper.contains(entry.key)) return entry.value;
    }
    return null;
  }

  /// توكن logo.dev العام (publishable key — مصمّم ليُوضع في العميل، مش سر).
  static const String _logoDevToken = 'pk_VosyOg4TQym3BGOMQEjULQ';

  /// تجار إقليميون (خليج/مصر) مش موجودين في مجموعات الأيقونات المفتوحة، فنجيب
  /// شعارهم من logo.dev بالدومين عبر الشبكة (مطابقة بالاحتواء — الأطول/الأخص
  /// أولاً). أي تاجر له SVG مرفق بيكسب أولاً (أوفلاين)؛ ده للباقي فقط.
  static const Map<String, String> _merchantDomains = {
    'THE CHEFZ': 'thechefz.com',
    'AL TAZAJ': 'altazaj.com',
    'MAMA NOURA': 'mamanoura.com.sa',
    'COOK DOOR': 'cookdoor.com',
    'MAESTRO PIZZA': 'maestropizza.com',
    'HALF MILLION': 'halfmillion.com.sa',
    'DR CAFE': 'drcafe.com',
    'SHARAF DG': 'sharafdg.com',
    'MAX FASHION': 'maxfashion.com',
    'HOME CENTRE': 'homecentre.com',
    'GOLDS GYM': 'goldsgym.com',
    'FITNESS TIME': 'fitnesstime.com.sa',
    'WATCH IT': 'watchit.com',
    'TALABAT': 'talabat.com',
    'ELMENUS': 'elmenus.com',
    'BREADFAST': 'breadfast.com',
    'HUNGERSTATION': 'hungerstation.com',
    'MRSOOL': 'mrsool.co',
    'JAHEZ': 'jahez.net',
    'ALBAIK': 'albaik.com',
    'HERFY': 'herfy.com',
    'KUDU': 'kudu.com.sa',
    'SHAWARMER': 'shawarmer.com',
    'KEBABJI': 'kebabji.com',
    'ZOOBA': 'zooba.com',
    'BARNS': 'barnscoffee.com',
    'SPINNEYS': 'spinneys.com',
    'SEOUDI': 'seoudisupermarket.com',
    'KAZYON': 'kazyon.com',
    'PANDA': 'panda.com.sa',
    'OTHAIM': 'othaimmarkets.com',
    'DANUBE': 'danube.sa',
    'TAMIMI': 'tamimimarkets.com',
    'LULU': 'luluhypermarket.com',
    'BINDAWOOD': 'bindawoodstores.com',
    'NESTO': 'nesto.com',
    'RABBIT': 'rabbitmart.com',
    'JARIR': 'jarir.com',
    'BTECH': 'btech.com',
    'JUMIA': 'jumia.com',
    'SHEIN': 'shein.com',
    'NAMSHI': 'namshi.com',
    'CENTREPOINT': 'centrepointstores.com',
    'SPLASH': 'splashfashions.com',
    'BABYSHOP': 'babyshopstores.com',
    'REDTAG': 'redtagfashion.com',
    'TRADELINE': 'tradeline.me',
    'CAREEM': 'careem.com',
    'SWVL': 'swvl.com',
    'INDRIVE': 'indrive.com',
    'JEENY': 'jeeny.me',
    'SAPTCO': 'saptco.com.sa',
    'ARAMCO': 'aramco.com',
    'PETROMIN': 'petromin.com',
    'SASCO': 'sasco.com.sa',
    'ADNOC': 'adnoc.ae',
    'ENOC': 'enoc.com',
    'EMARAT': 'emarat.ae',
    'ETISALAT': 'etisalat.ae',
    'MOBILY': 'mobily.com.sa',
    'OOREDOO': 'ooredoo.com',
    'DEWA': 'dewa.gov.ae',
    'BATELCO': 'batelco.com',
    'NAHDI': 'nahdionline.com',
    'ALDAWAA': 'al-dawaa.com',
    'ELEZABY': 'elezabypharmacy.com',
    'VEZEETA': 'vezeeta.com',
    'DALLAH': 'dallah-hospital.com',
    'MAGRABI': 'magrabi.com',
    'ANGHAMI': 'anghami.com',
    'SHAHID': 'shahid.net',
    'SAUDIA': 'saudia.com',
    'FLYNAS': 'flynas.com',
    'FLYADEAL': 'flyadeal.com',
    'EGYPTAIR': 'egyptair.com',
    'ALMOSAFER': 'almosafer.com',
    'TAJAWAL': 'tajawal.com',
    'ETIHAD': 'etihad.com',
    'SEPHORA': 'sephora.com',
    'NSTYLE': 'nstyleintl.com',
    'LEEJAM': 'leejam.com.sa',
    'BODYMASTERS': 'bodymasters.com.sa',
    'TABBY': 'tabby.ai',
    'TAMARA': 'tamara.co',
    'INSTAPAY': 'instapay.eg',
    'TAWUNIYA': 'tawuniya.com',
    'MEDGULF': 'medgulf.com.sa',
    // ── تغطية موسّعة: باقي تجار الـ seeds (متعدد الكلمات أولاً) ──
    'BUFFALO BURGER': 'buffaloburger.com',
    'TEXAS CHICKEN': 'texaschicken.com',
    'LITTLE CAESARS': 'littlecaesars.com',
    'PAPA JOHNS': 'papajohns.com',
    'SHAKE SHACK': 'shakeshack.com',
    'TIM HORTONS': 'timhortons.com',
    'SECOND CUP': 'secondcup.com',
    'GLORIA JEANS': 'gloriajeans.com',
    'UNION COOP': 'unioncoop.ae',
    'AL MAYA': 'almaya.ae',
    'HYPER ONE': 'hyperone.com.eg',
    'REEL CINEMAS': 'reelcinemas.com',
    'FITNESS FIRST': 'fitnessfirst.com',
    'DAR AL FOUAD': 'daralfouad.org',
    'SAUDI GERMAN': 'sghgroup.com.sa',
    'AL HABIB': 'hmg.com',
    'BRITISH COUNCIL': 'britishcouncil.org',
    'INSTASHOP': 'instashop.com',
    'MOMEN': 'momen.com',
    'HARDEES': 'hardees.com',
    'COSTA': 'costacoffee.com',
    'CARIBOU': 'cariboucoffee.com',
    'DUNKIN': 'dunkindonuts.com',
    'CILANTRO': 'cilantro.com.eg',
    'JOFFREYS': 'joffreys.com',
    'ARABICA': 'arabica.coffee',
    'CHOITHRAMS': 'choithrams.com',
    'ALMEERA': 'almeera.com.qa',
    'GRANDIOSE': 'grandiose.ae',
    'GOURMET': 'gourmetegypt.com',
    'RAGAB': 'ragabsons.com',
    'VIRGIN': 'virginmegastore.com',
    'AMAZON': 'amazon.com',
    'AMZN': 'amazon.com',
    'TEMU': 'temu.com',
    'ADOBE': 'adobe.com',
    'MICROSOFT': 'microsoft.com',
    'BOLT': 'bolt.eu',
    'YANGO': 'yango.com',
    'TOYOU': 'toyou.io',
    'TOTALENERGIES': 'totalenergies.com',
    'MOBIL': 'mobil.com',
    'STC': 'stc.com.sa',
    'ZAIN': 'zain.com',
    'MOUWASAT': 'mouwasat.com',
    'ANDALUSIA': 'andalusiagroup.net',
    'CLEOPATRA': 'cleopatrahospitals.com',
    'DISNEY': 'disneyplus.com',
    'VOX': 'voxcinemas.com',
    'MUVI': 'muvicinemas.com',
    'CINEPOLIS': 'cinepolis.com',
    'FLYDUBAI': 'flydubai.com',
    'WEGO': 'wego.com',
    'AGODA': 'agoda.com',
    'BOOKING': 'booking.com',
    'SKYSCANNER': 'skyscanner.net',
    'FACES': 'faces.com',
    'BUPA': 'bupa.com.sa',
    'NAGWA': 'nagwa.com',
    'ORMAN': 'orman.org.eg',
    'EHSAN': 'ehsan.sa',
    // ── اشتراكات وفواتير وأقساط إضافية ──
    'YOUTUBE PREMIUM': 'youtube.com',
    'AMAZON PRIME': 'primevideo.com',
    'OSN': 'osnplus.com',
    'STARZPLAY': 'starzplay.com',
    'JAWWY': 'jawwy.sa',
    'WEYYAK': 'weyyak.com',
    'MIDJOURNEY': 'midjourney.com',
    'CHATGPT': 'openai.com',
    'TOD': 'tod.tv',
    'VIU': 'viu.com',
    'VALU': 'valu.com.eg',
    'SOUHOOLA': 'souhoola.com',
    'HALAN': 'halan.com',
    'FORSA': 'forsa.com',
    'PERPLEXITY': 'perplexity.ai',
    'BEIN': 'bein.com',
    'XBOX': 'xbox.com',
    'LINKEDIN': 'linkedin.com',
    'MADFU': 'madfu.com.sa',
    'EMKAN': 'emkan.com.sa',
    'SYMPL': 'sympl.ai',
    'CONTACT': 'contact.eg',
    'AMAN': 'aman.com.eg',
    'SHAHRY': 'shahry.com',
    'KHAZNA': 'khazna.app',
    'POSTPAY': 'postpay.io',
    'CASHEW': 'cashewpayments.com',
    // أسماء عربية شائعة → نفس الدومين
    'بنده': 'panda.com.sa',
    'العثيم': 'othaimmarkets.com',
    'النهدي': 'nahdionline.com',
    'الدواء': 'al-dawaa.com',
    'كريم': 'careem.com',
    'طلبات': 'talabat.com',
    'مرسول': 'mrsool.co',
    'جاهز': 'jahez.net',
    'البيك': 'albaik.com',
    'كازيون': 'kazyon.com',
    'العزبي': 'elezabypharmacy.com',
    'شاهد': 'shahid.net',
    'المسافر': 'almosafer.com',
  };

  /// يبني رابط شعار logo.dev لاسم التاجر لو ليه دومين معروف، وإلا null.
  static String? logoDevUrlFor(String name) {
    final upper = name.toUpperCase();
    for (final entry in _merchantDomains.entries) {
      if (upper.contains(entry.key)) {
        return 'https://img.logo.dev/${entry.value}'
            '?token=$_logoDevToken&size=128&format=png';
      }
    }
    return null;
  }

  /// هل [name] علامة معروفة (شعار حقيقي أو مربّع ملوّن مميّز)؟ تُستخدم لتقرّر
  /// إظهار شعار العلامة بدل أيقونة التصنيف في صف العملية.
  static bool hasBrand(String name) {
    if (_resolveSlug(name) != null) return true;
    if (logoDevUrlFor(name) != null) return true;
    final upper = name.toUpperCase();
    for (final key in _brands.keys) {
      if (upper.contains(key.toUpperCase())) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    // 0) شعار من الـ admin/DB (URL) — لو فشل التحميل نرجع للبديل.
    if (logoUrl != null && logoUrl!.isNotEmpty) {
      return _networkLogo(logoUrl!, fallback: _drawnMark());
    }
    return _drawnMark();
  }

  /// مربّع أبيض بشعار من الشبكة، مع [fallback] لو فشل التحميل/أثناء التحميل.
  Widget _networkLogo(String url, {required Widget fallback}) {
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Image.network(
        url,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => fallback,
        loadingBuilder: (ctx, child, progress) =>
            progress == null ? child : fallback,
      ),
    );
  }

  Widget _drawnMark() {
    // 1) شعار SVG حقيقي لو موجود (صريح أو مكتشف تلقائياً من الملفات المرفقة).
    final slug = _resolveSlug(name);
    if (slug != null) {
      return Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(size * 0.18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(size * 0.28),
        ),
        child: SvgPicture.asset(
          'assets/brands/$slug.svg',
          fit: BoxFit.contain,
        ),
      );
    }

    // 2) شعار إقليمي من logo.dev عبر الشبكة (لو التاجر له دومين معروف).
    final logoDevUrl = logoDevUrlFor(name);
    if (logoDevUrl != null) {
      return _networkLogo(logoDevUrl, fallback: _letterMark());
    }

    // 3) مربّع ملوّن + حرف (بديل بدون شعار).
    return _letterMark();
  }

  Widget _letterMark() {
    final upper = name.toUpperCase();
    Color color = const Color(0xFF0A2540);
    String label = name.isNotEmpty ? name.characters.first : '?';
    for (final entry in _brands.entries) {
      if (upper.contains(entry.key.toUpperCase())) {
        color = entry.value.$1;
        label = entry.value.$2.isEmpty
            ? (name.isNotEmpty ? name.characters.first : '?')
            : entry.value.$2;
        break;
      }
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: size * (label.length > 2 ? 0.32 : 0.46),
        ),
      ),
    );
  }
}
