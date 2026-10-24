#!/bin/bash
# Read-only refusal gate. No service executable or target mutation is permitted.
# The embedded pure checks are planning checks, never execution authority.
set -euo pipefail
script_dir="${BASH_SOURCE[0]%/*}"
repo_root="$(cd -- "$script_dir/../../.." && pwd -P)"
exec /usr/bin/env -i PATH= /usr/bin/python3 -I - "$repo_root" "$@" <<'PYTHON_ENGINE'
# PYTHON_ENGINE_BEGIN
import argparse
import pathlib
import re
import sys

PROTECTED = ("qirsh_beta1_sync_rc5800", "qirsh_proof", "frasaaaaa")
PHASES = ("baseline", "apply", "concurrency", "rollback", "teardown")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_runtime_path(value, repo, home):
    path = pathlib.Path(value)
    require(path.is_absolute() and ".." not in path.parts, "unsafe runtime path")
    require(str(path) == value, "runtime path must be normalized")
    for protected in (pathlib.Path("/"), pathlib.Path(repo), pathlib.Path(home)):
        require(path != protected and path not in protected.parents,
                "protected runtime path")
    require(pathlib.Path(repo) not in path.parents and pathlib.Path(home) not in path.parents,
            "runtime must be outside repository and home")
    require(re.fullmatch(r"qirsh-fence-[a-z0-9][a-z0-9-]{0,31}", path.name),
            "invalid runtime token")
    require(not any(name in value for name in PROTECTED), "protected project")
    for part in (path,) + tuple(path.parents):
        require(not part.is_symlink(), "symlink runtime path")
    if path.exists():
        require(path.is_dir(), "runtime is not a directory")
        require(next(path.iterdir(), None) is None, "runtime is not new or empty")
    return path


def validate_plan(plan):
    # These are untrusted synthetic assertions, not runtime observations.
    require(set(plan) == {"cli_version", "ports", "bindings", "occupied",
                         "services", "images", "credentials", "environment_refs"},
            "incomplete or unknown plan fields")
    require(plan["cli_version"] == "2.117.0", "unreviewed CLI version")
    require(set(plan["ports"]) == {"db", "api"}, "incomplete exposed port set")
    ports = list(plan["ports"].values())
    require(all(type(port) is int and 1024 <= port <= 65535 for port in ports),
            "invalid port")
    require(len(set(ports)) == len(ports), "duplicate port")
    require(plan["bindings"] == {"db": "127.0.0.1", "api": "127.0.0.1"},
            "non-loopback or incomplete bindings")
    require(plan["occupied"] == [], "occupied port")
    services = {"postgres", "auth", "storage", "postgrest"}
    require(set(plan["services"]) == services and len(plan["services"]) == 4,
            "unexpected service set")
    require(set(plan["images"]) == services and all(
        re.fullmatch(r"sha256:[0-9a-f]{64}", digest)
        for digest in plan["images"].values()), "unpinned image")
    require(plan["credentials"] == "fresh-task-generated", "shared credential provenance")
    require(plan["environment_refs"] == [], "inherited environment reference")


def validate_manifest(expected, observed, partial=False):
    require(set(expected) == {"runtime", "project", "source_sha", "resources"},
            "invalid expected manifest")
    require(set(observed) == set(expected), "incomplete observed manifest")
    require(re.fullmatch(r"[0-9a-f]{64}", expected["source_sha"]), "invalid source hash")
    require(re.fullmatch(r"qirsh-fence-[a-z0-9][a-z0-9-]{0,31}", expected["project"]),
            "invalid project identity")
    require(not any(name in expected["project"] for name in PROTECTED), "protected project")
    for key in ("runtime", "project", "source_sha"):
        require(expected[key] == observed[key], "manifest identity mismatch")
    def resources(items):
        result = set()
        for item in items:
            require(set(item) == {"kind", "id", "project"}, "invalid resource fields")
            require(item["kind"] in ("container", "network", "volume"), "invalid resource kind")
            require(isinstance(item["id"], str) and item["id"] and
                    not any(name in item["id"] for name in PROTECTED), "protected resource")
            require(item["project"] == expected["project"], "foreign resource")
            key = (item["kind"], item["id"])
            require(key not in result, "duplicate resource")
            result.add(key)
        return result
    owned = resources(expected["resources"])
    actual = resources(observed["resources"])
    require(bool(owned) and (actual <= owned if partial else actual == owned),
            "resource inventory mismatch")


def validate_phase(phase, evidence, identity):
    # State and catalog digests are test inputs; a local marker alone is insufficient.
    require(phase in PHASES + ("post-rollback",), "unknown phase")
    require(evidence.get("identity") == identity, "phase identity mismatch")
    require(set(identity) == {"runtime", "project", "source_sha", "baseline_sha"} and
            all(re.fullmatch(r"[0-9a-f]{64}", identity[key])
                for key in ("source_sha", "baseline_sha")), "invalid phase identity")
    previous, catalog = {
        "baseline": ("new", identity["baseline_sha"]),
        "apply": ("baseline", identity["baseline_sha"]),
        "concurrency": ("applied", identity["source_sha"]),
        "rollback": ("applied", identity["source_sha"]),
        "post-rollback": ("rolled-back", identity["baseline_sha"]),
        "teardown": ("restored", identity["baseline_sha"]),
    }[phase]
    require(evidence.get("state") == previous, "out-of-order phase")
    require(evidence.get("observed_catalog_sha") == catalog, "missing catalog observation")
    if phase == "teardown":
        require(evidence.get("inventory_verified") is True, "missing exact inventory check")


def main(argv):
    parser = argparse.ArgumentParser(description="Disabled disposable harness safety gate")
    parser.add_argument("--runtime-dir", required=True)
    parser.add_argument("--phase", choices=PHASES)
    parser.add_argument("--post-start", action="store_true")
    args = parser.parse_args(argv[1:])
    # Deliberately do not inspect caller environment or runtime marker contents.
    try:
        validate_runtime_path(args.runtime_dir, argv[0], str(pathlib.Path.home()))
    except (ValueError, OSError):
        print("PREFLIGHT REFUSED: unsafe runtime path", file=sys.stderr)
        return 1
    print("RUNTIME_BLOCKED: Supabase CLI 2.117.0 has no reviewed pre-launch "
          "loopback binding, fresh credential and pinned image contract; "
          "no service command or phase was executed.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
# PYTHON_ENGINE_END
PYTHON_ENGINE
