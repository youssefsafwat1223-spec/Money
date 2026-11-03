import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/settings/settings_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';
class _Keys implements DatabaseKeyStore {
 @override Future<String> readOrCreateKey() async => 'profile-memory';
 @override Future<String?> readStoredKey() async => 'profile-memory';
}
class _FailureSettings extends DriftUserSettingsRepository {
 _FailureSettings(super.db);
 int calls=0;Completer<void> gate=Completer<void>();final inputs=<String?>[];
 @override Future<UserSettingsEntity> saveSettings(UserSettingsEntity settings) async {
  calls++;inputs.add(settings.displayName);await gate.future;throw StateError('private_profile_failure');
 }
}
Future<Map<String,List<Map<String,Object?>>>> _sql(AppDatabase db) async {
 final names=await db.customSelect("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").get();
 return {for(final n in names) n.read<String>('name'):[for(final row in await db.customSelect('SELECT * FROM "${n.read<String>('name')}"').get()) row.data]};
}
void main(){
 setUp(() {TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (call) async => null);});
 tearDown(() {TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), null);});
 for(final lang in ['ar','en']) {for(final dark in [false,true]) {
 testWidgets('actual profile Save pending error retry $lang dark$dark',(tester) async {
  tester.view.physicalSize=const Size(375,667);tester.view.devicePixelRatio=1;addTearDown(tester.view.reset);
  final db=await AppDatabase.open(executor:NativeDatabase.memory(),keyStore:_Keys(),initialLanguage:lang);
  final before=await _sql(db);final repository=_FailureSettings(db);
  await tester.pumpWidget(ProviderScope(overrides:[appDatabaseProvider.overrideWithValue(db),userSettingsRepositoryProvider.overrideWithValue(repository)],child:MaterialApp(theme:dark?AppTheme.dark:AppTheme.light,locale:Locale(lang),supportedLocales:AppL10n.supportedLocales,localizationsDelegates:AppL10n.localizationsDelegates,home:const SettingsScreen())));
  for(var i=0;i<5;i++){await tester.runAsync(() async=>Future<void>.delayed(const Duration(milliseconds:50)));await tester.pump(const Duration(milliseconds:100));}
  await tester.pumpAndSettle();final l=AppL10n.of(tester.element(find.byType(SettingsScreen)));
  await tester.tap(find.text(l.homeMoneyFriend).first);await tester.pumpAndSettle();
  final input=find.byType(TextField);expect(input,findsOneWidget);
  await tester.enterText(input,'  QA retained name  ');tester.testTextInput.hide();await tester.pumpAndSettle();
  final save=find.widgetWithText(FilledButton,l.setSave);await tester.ensureVisible(save);await tester.tap(save);await tester.pump();
  final disabled=tester.widget<FilledButton>(save).onPressed==null;final busy=find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
  await tester.tap(save,warnIfMissed:false);await tester.pump();final callsWhileHeld=repository.calls;
  repository.gate.complete();await tester.pumpAndSettle();final escaped=tester.takeException();final toast=find.text(l.setupSaveFailed).evaluate().isNotEmpty;
  final retained=tester.widget<TextField>(input).controller!.text;final retryEnabled=tester.widget<FilledButton>(save).onPressed!=null;
  repository.gate=Completer<void>();await tester.tap(save);await tester.pump();repository.gate.complete();await tester.pumpAndSettle();final escapedRetry=tester.takeException();
  await tester.pump(const Duration(seconds:4));await tester.pumpAndSettle();Navigator.of(tester.element(input)).pop();await tester.pump();await tester.pump(const Duration(milliseconds:100));final reverseError=tester.takeException();await tester.pumpAndSettle();
  final after=await _sql(db);final actualInputs=List<String?>.of(repository.inputs);await tester.pumpWidget(const SizedBox.shrink());await tester.pumpAndSettle();await db.close();
  expect(disabled,isTrue);expect(busy,isTrue);expect(callsWhileHeld,1);expect(escaped,isNull);expect(escapedRetry,isNull);expect(toast,isTrue);expect(retained,'  QA retained name  ');expect(retryEnabled,isTrue);expect(actualInputs,['QA retained name','QA retained name']);expect(reverseError,isNull);expect(after,before);
 });}}
}
