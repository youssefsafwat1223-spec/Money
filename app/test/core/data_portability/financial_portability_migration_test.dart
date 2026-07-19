import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('0044 keeps imports owner-only, atomic and reversible', () async {
    final migration = await File(
      '../supabase/migrations/0044_financial_data_portability.sql',
    ).readAsString();
    final rollback = await File(
      '../supabase/rollback/0044_financial_data_portability_rollback.sql',
    ).readAsString();

    expect(
        migration,
        contains(
            'alter table public.user_categories enable row level security'));
    expect(migration, contains('user_categories_owner'));
    expect(migration, contains('user_id = auth.uid()'));
    expect(migration, contains('security invoker'));
    expect(
        migration,
        contains(
            "revoke execute on function public.import_financial_package(text,text,jsonb) from anon"));
    expect(migration,
        contains('update public.user_transactions set deleted_at=now()'));
    expect(migration, isNot(contains('delete from public.user_transactions')));
    expect(migration, contains("'portable:'||(r->>'record_id')"));
    expect(migration, isNot(contains("'import:'||p_import_id||':'")));
    expect(migration, contains('run_row.mode <> p_mode'));
    expect(rollback,
        contains('drop function if exists public.import_financial_package'));
    expect(rollback, contains('drop table if exists public.user_categories'));
  });
}
