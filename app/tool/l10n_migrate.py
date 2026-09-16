#!/usr/bin/env python3
"""Migrate simple Arabic literals in one Dart file into the ARB pair.

Usage: l10n_migrate.py <dart file> <mapping.py with M = [(key, ar, en), ...]>

Deliberately narrow. It migrates only NON-INTERPOLATED literals, rewrites call
sites to `context.l10n.<key>`, then leaves `flutter analyze` to surface the
const/scope fallout, which is fixed by the caller. Interpolated strings need a
human decision about placeholders and are never touched.
"""
import collections, json, importlib.util, re, sys

def load(mapping_path):
    spec = importlib.util.spec_from_file_location('m', mapping_path)
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    return mod.M

def main(dart, mapping_path):
    M = load(mapping_path)
    for path, idx in (('lib/l10n/app_ar.arb', 1), ('lib/l10n/app_en.arb', 2)):
        arb = json.load(open(path, encoding='utf-8'),
                        object_pairs_hook=collections.OrderedDict)
        added = 0
        for key, ar, en in M:
            if key in arb:
                # Reusing an existing key is fine ONLY if it says the same
                # thing. If it does not, the rewrite silently swaps shipped
                # copy for different words — «الحساب» became «حساب» this way
                # before this check existed.
                existing = arb[key]
                intended = ar if idx == 1 else en
                if existing != intended:
                    raise SystemExit(
                        f"REFUSING: key {key!r} already means {existing!r}, "
                        f"not {intended!r} in {path}. Use a distinct key.")
                continue
            arb[key] = ar if idx == 1 else en
            added += 1
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(arb, f, ensure_ascii=False, indent=2); f.write('\n')
        print(f"  {path}: +{added}")

    s = open(dart, encoding='utf-8').read()
    n = 0
    # Longest Arabic first, so a short string never eats part of a longer one.
    for key, ar, _ in sorted(M, key=lambda t: -len(t[1])):
        lit = f"'{ar}'"
        if lit not in s:
            continue
        n += s.count(lit)
        s = s.replace(lit, f'context.l10n.{key}')
    open(dart, 'w', encoding='utf-8').write(s)
    print(f"  {dart}: {n} occurrences -> context.l10n.*")

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
