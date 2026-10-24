"""Hermetic validation/refusal tests. No runtime, SQL or network proof.

Only root may execute these after reviewing the frozen source containment.
"""
import ast
import copy
import os
import pathlib
import subprocess
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
ENGINE = (HERE / "preflight.sh").read_text().split(
    "# PYTHON_ENGINE_BEGIN\n", 1)[1].split("# PYTHON_ENGINE_END", 1)[0]
API = {"__name__": "synthetic_harness_validation"}
exec(compile(ENGINE, "embedded-preflight", "exec"), API)


def plan():
    services = ["postgres", "auth", "storage", "postgrest"]
    return {"cli_version": "2.117.0", "ports": {"db": 1024, "api": 65535},
            "bindings": {"db": "127.0.0.1", "api": "127.0.0.1"},
            "occupied": [], "services": services,
            "images": {name: "sha256:" + "a" * 64 for name in services},
            "credentials": "fresh-task-generated", "environment_refs": []}


def manifest():
    return {"runtime": "synthetic-runtime", "project": "qirsh-fence-unit",
            "source_sha": "a" * 64,
            "resources": [{"kind": kind, "id": "synthetic-" + kind,
                           "project": "qirsh-fence-unit"}
                          for kind in ("container", "network", "volume")]}


class PureValidationTests(unittest.TestCase):
    def test_plan_positive_and_refusals(self):
        API["validate_plan"](plan())
        cases = []
        for port in (0, 1023, 65536, "54322", True):
            item = plan(); item["ports"]["db"] = port; cases.append(item)
        for bind in ("0.0.0.0", "::", "localhost", "example.invalid"):
            item = plan(); item["bindings"]["api"] = bind; cases.append(item)
        for key, value in (("ports", {"db": 1234, "api": 1234}),
                           ("ports", {"db": 1234}), ("occupied", [1024]),
                           ("cli_version", "2.118.0"),
                           ("credentials", "postgres-default"),
                           ("environment_refs", ["OPENAI_API_KEY"]),
                           ("services", ["postgres", "auth", "storage", "postgrest", "studio"]),
                           ("images", {"postgres": "latest"})):
            item = plan(); item[key] = value; cases.append(item)
        item = plan(); item["pull_on_start"] = True; cases.append(item)
        item = plan(); item["services"] = ["postgres", "auth", "storage"]; cases.append(item)
        item = plan(); item["images"]["auth"] = "supabase/auth:latest"; cases.append(item)
        item = plan(); del item["images"]["storage"]; cases.append(item)
        item = plan(); item["occupied"] = [65535]; cases.append(item)
        item = plan(); item["ports"] = {"db": 1024, "api": 1024}; cases.append(item)
        item = plan(); item["bindings"] = {"db": "127.0.0.1", "api": "127.0.0.1", "studio": "0.0.0.0"}; cases.append(item)
        item = plan(); item["credentials"] = "shared-default"; cases.append(item)
        item = plan(); item["environment_refs"] = ["env(S3_KEY)"]; cases.append(item)
        for item in cases:
            with self.subTest(case=cases.index(item)):
                with self.assertRaises(ValueError): API["validate_plan"](item)

    def test_manifest_exact_partial_and_refusals(self):
        expected = manifest()
        API["validate_manifest"](expected, copy.deepcopy(expected))
        partial = manifest(); partial["resources"] = partial["resources"][:1]
        API["validate_manifest"](expected, partial, partial=True)
        cases = []
        for key in ("runtime", "project", "source_sha"):
            item = manifest(); item[key] = "foreign"; cases.append(item)
        item = manifest(); item["resources"].append(item["resources"][0]); cases.append(item)
        item = manifest(); item["resources"][0]["id"] = "qirsh_proof"; cases.append(item)
        item = manifest(); item["resources"][0]["project"] = "foreign"; cases.append(item)
        item = manifest(); item["resources"] = []; cases.append(item)
        item = manifest(); item["resources"][0]["id"] = "other-container"; cases.append(item)
        item = {"project": "qirsh-fence-unit"}; cases.append(item)
        item = manifest(); item["resources"][1]["kind"] = "image"; cases.append(item)
        item = manifest(); item["resources"][1]["id"] = "frasaaaaa"; cases.append(item)
        item = manifest(); item["resources"][1]["id"] = "qirsh_beta1_sync_rc5800"; cases.append(item)
        item = manifest(); item["marker"] = "project_id=forged"; cases.append(item)
        item = manifest(); item["resources"][0]["extra"] = 1; cases.append(item)
        for index, item in enumerate(cases):
            with self.subTest(case=index):
                with self.assertRaises(ValueError): API["validate_manifest"](expected, item)

    def test_phase_positive_progression_and_refusals(self):
        identity = {"runtime": "synthetic-runtime", "project": "qirsh-fence-unit",
                    "source_sha": "a" * 64, "baseline_sha": "b" * 64}
        for phase, state, digest in (("baseline", "new", "b"),
                                    ("apply", "baseline", "b"),
                                    ("concurrency", "applied", "a"),
                                    ("rollback", "applied", "a"),
                                    ("post-rollback", "rolled-back", "b"),
                                    ("teardown", "restored", "b")):
            evidence = {"identity": identity, "state": state,
                        "observed_catalog_sha": digest * 64, "inventory_verified": True}
            API["validate_phase"](phase, evidence, identity)
            for key, wrong in (("identity", {}), ("state", "already-finished"),
                               ("observed_catalog_sha", "c" * 64)):
                bad = copy.deepcopy(evidence); bad[key] = wrong
                with self.subTest(phase=phase, field=key):
                    with self.assertRaises(ValueError): API["validate_phase"](phase, bad, identity)
        with self.assertRaises(ValueError):
            API["validate_phase"]("apply", {"phase_marker": "baseline"}, identity)
        with self.assertRaises(ValueError):  # repeated baseline after apply
            API["validate_phase"]("baseline", {"identity": identity, "state": "baseline",
                                  "observed_catalog_sha": "b" * 64}, identity)
        with self.assertRaises(ValueError):  # teardown before restoration
            API["validate_phase"]("teardown", {"identity": identity, "state": "applied",
                                  "observed_catalog_sha": "a" * 64,
                                  "inventory_verified": True}, identity)
        with self.assertRaises(ValueError):  # unknown phase
            API["validate_phase"]("provision", {"identity": identity, "state": "new",
                                  "observed_catalog_sha": "b" * 64}, identity)
        corrupt = dict(identity, source_sha="not-a-hash")
        with self.assertRaises(ValueError):  # corrupt identity hash
            API["validate_phase"]("baseline", {"identity": corrupt, "state": "new",
                                  "observed_catalog_sha": "b" * 64}, corrupt)
        with self.assertRaises(ValueError):  # missing catalog observation
            API["validate_phase"]("concurrency", {"identity": identity, "state": "applied"}, identity)
        with self.assertRaises(ValueError):
            API["validate_phase"]("teardown", {"identity": identity, "state": "restored",
                                  "observed_catalog_sha": "b" * 64}, identity)

    def test_paths_and_preservation(self):
        with tempfile.TemporaryDirectory(prefix="fence-path-tests-") as tmp:
            root = pathlib.Path(tmp).resolve()
            repo = root / "repo"; repo.mkdir()
            home = root / "home"; home.mkdir()
            good = root / "qirsh-fence-unit"
            self.assertEqual(API["validate_runtime_path"](str(good), str(repo), str(home)), good)
            good.mkdir()
            API["validate_runtime_path"](str(good), str(repo), str(home))
            foreign = root / "qirsh-fence-foreign"; foreign.mkdir()
            sentinel = foreign / "sentinel"; sentinel.write_text("preserve")
            link = root / "qirsh-fence-link"; link.symlink_to(good, target_is_directory=True)
            parent = root / "alias"; parent.symlink_to(root, target_is_directory=True)
            file = root / "qirsh-fence-file"; file.write_text("preserve")
            paths = ["relative", "/", str(home), str(repo), str(root), str(link),
                     str(parent / "qirsh-fence-child"), str(file), str(foreign),
                     str(repo / "qirsh-fence-child"), str(home / "qirsh-fence-child"),
                     str(root / ".." / "qirsh-fence-unit"),
                     str(root / "supabase"), str(root / "qirsh-fence-qirsh_proof"),
                     str(root / "qirsh-fence-frasaaaaa"),
                     str(root / "qirsh-fence-qirsh_beta1_sync_rc5800")]
            for index, value in enumerate(paths):
                with self.subTest(case=index):
                    with self.assertRaises(ValueError):
                        API["validate_runtime_path"](value, str(repo), str(home))
            self.assertEqual(sentinel.read_text(), "preserve")
            self.assertEqual(file.read_text(), "preserve")


class CLIContainmentTests(unittest.TestCase):
    def test_engine_has_no_execution_or_network_primitives(self):
        imports = [node.names[0].name for node in ast.walk(ast.parse(ENGINE))
                   if isinstance(node, ast.Import)]
        self.assertEqual(set(imports), {"argparse", "pathlib", "re", "sys"})
        for script in ("run.sh",):
            text = (HERE / script).read_text()
            for forbidden in ("docker", "supabase ", "psql", "curl", "deno", "rm -",
                              "cp ", "mkdir", "config.toml"):
                self.assertNotIn(forbidden, text)
        for forbidden in ("subprocess", "socket", "os.system", "urllib", "shutil",
                          "supabase start", "supabase stop", "psql ", "curl ", "rm -"):
            self.assertNotIn(forbidden, ENGINE)

    def test_every_cli_refuses_without_external_calls_or_target_changes(self):
        old_umask = os.umask(0o077)
        try:
            with tempfile.TemporaryDirectory(prefix="fence-cli-tests-") as tmp:
                root = pathlib.Path(tmp).resolve()
                stubs = root / "bin"; stubs.mkdir()
                log = root / "commands"
                for command in ("docker", "supabase", "psql", "curl", "deno"):
                    stub = stubs / command
                    stub.write_text('#!/bin/bash\necho called >> "$MOCK_LOG"\nexit 99\n')
                    stub.chmod(0o700)
                home = root / "home"; home.mkdir()
                private_tmp = root / "tmp"; private_tmp.mkdir()
                target = root / "qirsh-fence-safe"
                # Synthetic only; do not import any real process environment.
                secret = "synthetic-do-not-print-7813"
                env = {"PATH": str(stubs), "HOME": str(home), "TMPDIR": str(private_tmp),
                       "MOCK_LOG": str(log), "OPENAI_API_KEY": secret,
                       "SUPABASE_ACCESS_TOKEN": secret, "FENCE_CAPABILITY_OVERRIDE": "yes",
                       "PYTHONPATH": str(root / "absent")}
                requests = [("preflight.sh", ["--runtime-dir", str(target)]),
                            ("preflight.sh", ["--runtime-dir", str(target), "--post-start"])]
                requests += [("run.sh", ["--runtime-dir", str(target), "--phase", phase])
                             for phase in ("baseline", "apply", "concurrency", "rollback", "teardown")]
                requests += [("run.sh", []), ("run.sh", ["--phase", "unknown"]),
                             ("run.sh", ["--runtime-dir", str(target)]),
                             ("preflight.sh", ["--unknown"])]
                for script, args in requests:
                    with self.subTest(script=script, args=args):
                        result = subprocess.run(["/bin/bash", "--noprofile", "--norc",
                                                 str(HERE / script)] + args,
                                                env=env, capture_output=True, text=True, timeout=10)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertNotIn(secret, result.stdout + result.stderr)
                        if "--runtime-dir" in args and ("--phase" in args or script == "preflight.sh"):
                            self.assertIn("RUNTIME_BLOCKED", result.stderr)
                        self.assertFalse(log.exists())
                        self.assertFalse(target.exists())
                target.mkdir()
                marker = target / ".qirsh-fence-runtime"; marker.write_text("project_id=counterfeit")
                sentinel = target / "foreign"; sentinel.write_text("preserve")
                before = {p.name: p.read_bytes() for p in target.iterdir()}
                result = subprocess.run(["/bin/bash", "--noprofile", "--norc", str(HERE / "run.sh"),
                                         "--runtime-dir", str(target), "--phase", "teardown"],
                                        env=env, capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(before, {p.name: p.read_bytes() for p in target.iterdir()})
                self.assertFalse(log.exists())
        finally:
            os.umask(old_umask)


if __name__ == "__main__":
    unittest.main()
