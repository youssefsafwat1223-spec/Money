/// يحوّل مفتاح أيقونة التصنيف (النصّي، كما يُخزَّن في الـ DB — نفس مفاتيح Lucide)
/// إلى إيموجي Unicode أصلي.
///
/// نرسمه عبر [Text] بخط النظام الافتراضي للإيموجي (Apple Color Emoji على iOS،
/// Noto Color Emoji على Android) — ملوّن بالكامل، بدون مكتبات أيقونات أو SVG.
String categoryEmoji(String key) {
  switch (key) {
    case 'utensils-crossed':
      return '🍽️';
    case 'shopping-basket':
      return '🛒';
    case 'shopping-bag':
      return '🛍️';
    case 'car-taxi-front':
      return '🚕';
    case 'fuel':
      return '⛽';
    case 'receipt-text':
      return '🧾';
    case 'heart-pulse':
      return '🩺';
    case 'graduation-cap':
      return '🎓';
    case 'clapperboard':
      return '🎬';
    case 'repeat':
      return '🔁';
    case 'arrow-left-right':
      return '🔄';
    case 'banknote':
      return '💵';
    case 'plane':
      return '✈️';
    case 'gift':
      return '🎁';
    case 'baby':
      return '👶';
    case 'house':
      return '🏠';
    case 'coffee':
      return '☕';
    case 'wrench':
      return '🔧';
    case 'wallet-cards':
      return '💳';
    case 'hotel':
      return '🏨';
    case 'scissors':
      return '✂️';
    case 'dumbbell':
      return '🏋️';
    case 'shield-check':
      return '🛡️';
    case 'dog':
      return '🐶';
    case 'cake':
      return '🎂';
    case 'heart-handshake':
      return '🤝';
    case 'piggy-bank':
      return '🐷';
    case 'shapes':
    default:
      return '🏷️';
  }
}
