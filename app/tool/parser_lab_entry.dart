// Entry point compiled to JS for the admin Parser Lab.
// Build: dart compile js tool/parser_lab_entry.dart -O2 -o ../admin/public/parser_lab.js
//
// Exposes window.parseSms(rawMessage: string, sender: string): string (JSON).
// Uses the SAME Dart engine as the app — single source of truth.

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:money_companion/engine/parser/bank_profile.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

void main() {
  globalContext['parseSms'] = ((JSString rawMessage, JSString sender) {
    const engine = ParserEngine();
    final senderStr = sender.toDart;
    final result = engine.parse(
      rawMessage.toDart,
      senderId: senderStr.isEmpty ? null : senderStr,
      bankProfiles: BankProfiles.all,
    );

    final map = <String, Object?>{
      'isTransaction': result.isTransaction,
      'bankKey': result.bankKey,
      'confidence': result.confidence,
    };

    if (result.isTransaction && result.transaction != null) {
      final txn = result.transaction!;
      map['amount'] = txn.amount;
      map['currency'] = txn.currency;
      map['type'] = txn.type.name;
      map['source'] = txn.source.name;
      map['merchant'] = txn.rawMerchant;
      map['cardLast4'] = txn.cardLast4;
      map['balanceAfter'] = txn.balanceAfter;
      map['occurredAt'] = txn.occurredAt?.toIso8601String();
      map['foreignAmount'] = txn.foreignAmount;
      map['foreignCurrency'] = txn.foreignCurrency;
      map['fundingSource'] = txn.fundingSource;
      map['parseConfidence'] = txn.parseConfidence;
    }

    return json.encode(map).toJS;
  }).toJS;
}
