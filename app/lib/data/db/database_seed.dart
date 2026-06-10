import '../../core/utils/id_generator.dart';
import '../../domain/entities/achievement_catalog.dart';
import '../../domain/entities/budget_entity.dart';
import '../../domain/entities/category_entity.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/entities/supporting_entities.dart';
import '../../engine/categorization/category.dart';
import '../../engine/categorization/category_seeds.dart';

class SeededMerchantMapping {
  const SeededMerchantMapping({
    required this.rawName,
    required this.categoryKey,
    this.confidence = 0.8,
  });

  final String rawName;
  final String categoryKey;
  final double confidence;
}

class DatabaseSeed {
  DatabaseSeed._();

  static final List<CategoryEntity> categories = [
    const CategoryEntity(
      id: BudgetEntity.allExpensesCategoryId,
      key: BudgetEntity.allExpensesCategoryKey,
      nameAr: 'كل المصروفات',
      icon: 'wallet-cards',
      color: '#AB47BC',
      isIncome: false,
      sort: -1,
    ),
    for (var index = 0; index < Categories.all.length; index++)
      CategoryEntity(
        id: IdGenerator.next(),
        key: Categories.all[index].key,
        nameAr: Categories.all[index].arName,
        icon: _iconFor(Categories.all[index].key),
        color: _colorFor(Categories.all[index].key),
        isIncome: Categories.all[index].key == Categories.income.key,
        sort: index,
      ),
  ];

  static final List<SeededMerchantMapping> merchantMappings = [
    for (final entry in CategorySeeds.keywordRules.entries)
      SeededMerchantMapping(
        rawName: entry.key,
        categoryKey: entry.value,
      ),
  ];

  static final List<GoalEntity> suggestedGoals = [
    GoalEntity(
      id: IdGenerator.next(),
      name: 'رحلة صيف',
      targetAmount: 6000,
      savedAmount: 0,
      deadline: DateTime.utc(DateTime.now().year, 8, 1),
      vaultSkin: 'summer_trip',
      status: 'active',
      createdAt: DateTime.now().toUtc(),
    ),
    GoalEntity(
      id: IdGenerator.next(),
      name: 'صندوق طوارئ',
      targetAmount: 15000,
      savedAmount: 0,
      deadline: null,
      vaultSkin: 'emergency_fund',
      status: 'active',
      createdAt: DateTime.now().toUtc(),
    ),
    GoalEntity(
      id: IdGenerator.next(),
      name: 'الحج / العمرة',
      targetAmount: 12000,
      savedAmount: 0,
      deadline: null,
      vaultSkin: 'hajj_umrah',
      status: 'active',
      createdAt: DateTime.now().toUtc(),
    ),
  ];

  static final List<AchievementEntity> achievements = [
    for (final definition in AchievementCatalog.all)
      AchievementEntity(
        id: IdGenerator.next(),
        key: definition.key,
        nameAr: definition.nameAr,
        progress: 0,
      ),
  ];

  static String _iconFor(String key) {
    switch (key) {
      case 'restaurants':
        return 'utensils-crossed';
      case 'groceries':
        return 'shopping-basket';
      case 'transport':
        return 'car-taxi-front';
      case 'fuel':
        return 'fuel';
      case 'bills':
        return 'receipt-text';
      case 'shopping':
        return 'shopping-bag';
      case 'health':
        return 'heart-pulse';
      case 'education':
        return 'graduation-cap';
      case 'entertainment':
        return 'clapperboard';
      case 'subscriptions':
        return 'repeat';
      case 'transfers':
        return 'arrow-left-right';
      case 'cash':
        return 'banknote';
      case 'travel':
        return 'plane';
      case 'gifts':
        return 'gift';
      case 'kids':
        return 'baby';
      case 'home':
        return 'house';
      case 'cafes':
        return 'coffee';
      case 'maintenance':
        return 'wrench';
      case 'income':
        return 'wallet-cards';
      case 'other':
      default:
        return 'shapes';
    }
  }

  static String _colorFor(String key) {
    switch (key) {
      case 'restaurants':
        return '#FF7043';
      case 'groceries':
        return '#43A047';
      case 'transport':
        return '#1E88E5';
      case 'fuel':
        return '#5E35B1';
      case 'bills':
        return '#546E7A';
      case 'shopping':
        return '#8E24AA';
      case 'health':
        return '#E53935';
      case 'education':
        return '#3949AB';
      case 'entertainment':
        return '#FB8C00';
      case 'subscriptions':
        return '#6D4C41';
      case 'transfers':
        return '#00897B';
      case 'cash':
        return '#7CB342';
      case 'travel':
        return '#00ACC1';
      case 'gifts':
        return '#D81B60';
      case 'kids':
        return '#F4511E';
      case 'home':
        return '#8D6E63';
      case 'cafes':
        return '#6D4C41';
      case 'maintenance':
        return '#757575';
      case 'income':
        return '#00C853';
      case 'other':
      default:
        return '#9E9E9E';
    }
  }
}
