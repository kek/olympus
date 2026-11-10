"""Trusted controller for bounded, black-box candidate programs. No third-party dependencies."""
import difflib
import hashlib
import json
import math
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid

VERSION = 1
MAX_SOURCE = 262144
MAX_EDIT = 32768
MAX_OUTPUT = 8192
MAX_CASES = 8
CANCELLED = threading.Event()


class Invalid(Exception):
    pass


def require(condition, reason):
    if not condition:
        raise Invalid(reason)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate_json_key")
        result[key] = value
    return result


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def digest(value):
    return hashlib.sha256(encoded(value)).hexdigest()


def safe_path(path):
    return (isinstance(path, str) and len(path) <= 240 and
            re.fullmatch(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*", path) is not None and
            all(p not in (".", "..", ".git", ".jj") for p in path.split("/")))


def command(args, *, timeout=10):
    require(not CANCELLED.is_set(), "cancelled")
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=timeout, check=False)
    require(result.returncode == 0, "tool_failed")
    return result.stdout


def git(repo, *args):
    # Object plumbing only: no checkout, hooks, filters, merge or working-copy mutation.
    return command(["git", "--no-replace-objects", "--literal-pathspecs", "-C", repo, *args])


def prepare(config):
    allowed = {"repository", "revision", "fixtures", "image", "command", "editable", "source_files", "case_timeout_ms", "owner"}
    require(isinstance(config, dict) and set(config) <= allowed, "invalid_profile")
    repo = str(Path(config["repository"]).resolve(strict=True))
    revision = config["revision"]
    require(isinstance(revision, str) and 0 < len(revision) <= 256 and not revision.startswith("-"), "invalid_revision")
    if (Path(repo) / ".jj").is_dir():
        commit = command(["jj", "--ignore-working-copy", "--at-op=@", "-R", repo, "log", "-r", revision,
                          "--no-graph", "-T", 'commit_id ++ "\\n"']).decode().strip()
    else:
        commit = git(repo, "rev-parse", "--verify", revision + "^{commit}").decode().strip()
    require(re.fullmatch(r"[0-9a-f]{40,64}", commit) is not None, "ambiguous_revision")

    listing = git(repo, "ls-tree", "-rz", "--full-tree", commit)
    entries = {}
    for row in listing.split(b"\0"):
        if not row:
            continue
        metadata, raw_path = row.split(b"\t", 1)
        mode, kind, blob = metadata.decode("ascii").split()
        entries[raw_path.decode("utf-8")] = (mode, kind, blob)
    paths = config.get("source_files", sorted(entries))
    require(isinstance(paths, list) and 0 < len(paths) <= 64 and len(set(paths)) == len(paths), "source_budget")
    files = {}
    modes = {}
    total = 0
    for path in paths:
        require(safe_path(path) and path in entries, "invalid_source_path")
        mode, kind, blob = entries[path]
        require(mode in ("100644", "100755") and kind == "blob", "unsupported_source_type")
        size = int(git(repo, "cat-file", "-s", blob))
        total += size
        require(total <= MAX_SOURCE, "source_budget")
        text = git(repo, "cat-file", "blob", blob).decode("utf-8")
        require("\0" not in text, "binary_source")
        require(not text.startswith("version https://git-lfs.github.com/spec/"), "lfs_unsupported")
        files[path] = text
        modes[path] = 0o755 if mode == "100755" else 0o644

    editable = config["editable"]
    require(isinstance(editable, list) and 0 < len(editable) <= 16 and
            len(set(editable)) == len(editable) and all(safe_path(p) for p in editable), "invalid_editable_paths")
    # Exact paths only; original Git modes are sealed and preserved.
    require(all(not any(q.startswith(p + "/") or p.startswith(q + "/") for q in files if q != p)
                for p in editable), "path_collision")
    fixture_path = Path(config["fixtures"])
    require(not fixture_path.is_symlink() and fixture_path.is_file(), "invalid_fixtures")
    fixture_path = fixture_path.resolve()
    require(not any((Path(repo) / path).resolve() == fixture_path for path in files), "fixtures_exposed")
    require(fixture_path.stat().st_size <= 65536, "fixture_budget")
    cases = json.loads(fixture_path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    validate_cases(cases)
    argv = config["command"]
    require(isinstance(argv, list) and 0 < len(argv) <= 32 and
            all(isinstance(a, str) and 0 < len(a) <= 1024 and "\0" not in a for a in argv), "invalid_command")
    case_timeout = config.get("case_timeout_ms", 3000)
    require(type(case_timeout) is int and 100 <= case_timeout <= 10000, "invalid_case_timeout")
    image = config["image"]
    require(isinstance(image, str) and len(image) <= 256 and not image.startswith("-"), "invalid_image")
    info = json.loads(command(["podman", "image", "inspect", image]))
    image_id = info[0]["Id"]
    if re.fullmatch(r"[0-9a-f]{64}", image_id):
        image_id = "sha256:" + image_id
    require(re.fullmatch(r"sha256:[0-9a-f]{64}", image_id) is not None, "invalid_image")
    owner = config["owner"]
    require(re.fullmatch(r"[0-9a-f]{64}", owner) is not None, "invalid_owner")
    root = Path(tempfile.gettempdir()) / ("olympus-workspaces-" + str(os.getuid()) + "-" + owner)
    # One live Fate per journal owns this label. Restart reaps unfinished execution.
    orphaned = command(["podman", "ps", "--all", "--quiet", "--filter", "label=olympus.owner=" + owner]).decode().split()
    if orphaned:
        command(["podman", "rm", "--force", "--time", "0", *orphaned])
    if root.exists():
        require(not root.is_symlink(), "invalid_workspace_root")
        shutil.rmtree(root)
    root.mkdir(mode=0o700)
    manifest = {
        "evaluator_version": VERSION, "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), "base_revision": commit,
        "source_sha256": digest({"files": files, "modes": modes}), "fixtures_sha256": digest(cases),
        "image": image_id, "platform": info[0]["Os"] + "/" + info[0]["Architecture"],
        "command": argv, "workdir": "/candidate",
        "environment": {"LANG": "C.UTF-8", "TZ": "UTC", "PYTHONDONTWRITEBYTECODE": "1"},
        "editable": sorted(editable), "case_count": len(cases),
        "case_timeout_ms": case_timeout, "max_edit_bytes": MAX_EDIT,
        "max_output_bytes": MAX_OUTPUT,
        "isolation": {"network": "none", "rootfs": "read-only", "source": "read-only",
                      "uid": 65534, "cpus": 1, "memory_mb": 256, "pids": 64, "tmp_mb": 16},
    }
    manifest["profile_sha256"] = digest(manifest)
    return {"manifest": manifest, "files": files, "modes": modes, "editable": sorted(editable), "cases": cases,
            "owner": owner, "workspace_root": str(root)}


def validate_cases(cases):
    require(isinstance(cases, list) and 0 < len(cases) <= MAX_CASES, "invalid_cases")
    for case in cases:
        require(isinstance(case, dict) and set(case) == {"stdin", "stdout", "exit_code"}, "invalid_case")
        require(type(case["exit_code"]) is int and case["exit_code"] == 0, "invalid_case")
        require(all(isinstance(case[k], str) and len(case[k].encode("utf-8")) <= MAX_OUTPUT
                    for k in ("stdin", "stdout")), "case_budget")


def validate_profile(profile):
    manifest = profile["manifest"]
    require(manifest["runner_sha256"] == hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), "runner_changed")
    require(re.fullmatch(r"[0-9a-f]{64}", profile["owner"]) is not None, "invalid_owner")
    root = Path(tempfile.gettempdir()) / ("olympus-workspaces-" + str(os.getuid()) + "-" + profile["owner"])
    require(str(root) == profile["workspace_root"] and root.is_dir() and not root.is_symlink(), "invalid_workspace_root")
    unsigned = {k: v for k, v in manifest.items() if k != "profile_sha256"}
    require(manifest["evaluator_version"] == VERSION and digest(unsigned) == manifest["profile_sha256"], "profile_changed")
    require(set(profile["modes"]) == set(profile["files"]) and
            all(mode in (0o644, 0o755) for mode in profile["modes"].values()), "invalid_source_modes")
    require(digest({"files": profile["files"], "modes": profile["modes"]}) == manifest["source_sha256"] and
            digest(profile["cases"]) == manifest["fixtures_sha256"] and
            profile["editable"] == manifest["editable"], "profile_changed")
    validate_cases(profile["cases"])


def diff_lines(text):
    # Unified patches split on LF only, not Unicode separators or lone CR.
    parts = text.split("\n")
    return [part + "\n" for part in parts[:-1]] + ([parts[-1]] if parts[-1] else [])


def make_patch(base, edits):
    chunks = []
    for path, text in sorted(edits.items()):
        before = base.get(path, "")
        if path in base and before == text:
            continue
        if path not in base and text == "":
            chunks.append("diff --git a/" + path + " b/" + path + "\nnew file mode 100644\nindex 0000000..e69de29\n")
            continue
        lines = difflib.unified_diff(diff_lines(before), diff_lines(text),
                                     fromfile="a/" + path if path in base else "/dev/null",
                                     tofile="b/" + path, lineterm="\n")
        for line in lines:
            chunks.append(line if line.endswith("\n") else line + "\n\\ No newline at end of file\n")
    return "".join(chunks)


def cleanup(name, proc):
    # Stop an attached CLI before removing: a flood can otherwise block removal on its full pipes.
    if proc.poll() is None:
        os.killpg(proc.pid, signal.SIGKILL)
    proc.wait(timeout=2)
    # Container lifetime also has an engine-enforced timeout if this controller dies.
    subprocess.run(["podman", "rm", "--force", "--time", "0", name],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)


def run_case(directory, manifest, case, deadline, owner):
    name = "olympus-" + uuid.uuid4().hex
    available = min(manifest["case_timeout_ms"] / 1000, deadline - time.monotonic())
    require(available > 0 and not CANCELLED.is_set(), "evaluation_timeout")
    end = time.monotonic() + available
    argv = manifest["command"]
    args = ["podman", "run", "--rm", "--pull=never", "--name", name,
            "--label", "olympus.evaluator=1", "--label", "olympus.owner=" + owner, "--timeout", str(max(1, math.ceil(available))),
            "--network=none", "--read-only", "--read-only-tmpfs=false", "--cap-drop=ALL",
            "--security-opt=no-new-privileges", "--user=65534:65534", "--cpus=1",
            "--memory=256m", "--memory-swap=256m", "--pids-limit=64", "--ulimit=nofile=64:64",
            "--ipc=private", "--pid=private", "--log-driver=none", "--workdir=/candidate",
            "--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=16777216,mode=1777",
            "--mount", "type=bind,src=" + directory + ",dst=/candidate,ro",
            "--env=LANG=C.UTF-8", "--env=TZ=UTC", "--env=PYTHONDONTWRITEBYTECODE=1",
            "--entrypoint", argv[0], "--interactive", manifest["image"], *argv[1:]]
    proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, start_new_session=True)
    out, err = bytearray(), bytearray()
    reason = "completed"
    try:
        proc.stdin.write(case["stdin"].encode("utf-8"))
        proc.stdin.close()
        with selectors.DefaultSelector() as selector:
            selector.register(proc.stdout, selectors.EVENT_READ, out)
            selector.register(proc.stderr, selectors.EVENT_READ, err)
            while selector.get_map():
                if CANCELLED.is_set() or time.monotonic() >= end:
                    reason = "cancelled" if CANCELLED.is_set() else "timeout"
                    break
                for key, _ in selector.select(timeout=min(0.05, max(end - time.monotonic(), 0))):
                    chunk = os.read(key.fileobj.fileno(), 4096)
                    if chunk:
                        key.data.extend(chunk)
                    else:
                        selector.unregister(key.fileobj)
                if len(out) + len(err) > MAX_OUTPUT:
                    reason = "output_budget"
                    break
        if reason == "completed":
            try:
                proc.wait(timeout=max(end - time.monotonic(), 0.001))
            except subprocess.TimeoutExpired:
                reason = "timeout"
        exit_code = proc.poll()
        if exit_code == 255 or exit_code == 137:
            reason = "killed_or_timeout"
    finally:
        cleanup(name, proc)
        proc.stdout.close()
        proc.stderr.close()
    passed = reason == "completed" and exit_code == case["exit_code"] and out == case["stdout"].encode("utf-8")
    return {"execution_id": name, "passed": passed, "reason": reason, "exit_code": exit_code,
            "stdout_sha256": hashlib.sha256(out).hexdigest(), "stderr_sha256": hashlib.sha256(err).hexdigest(),
            "stdout_preview": bytes(out[:256]).decode("utf-8", errors="replace"),
            "stderr_preview": bytes(err[:256]).decode("utf-8", errors="replace")}


def evaluate(profile, artifact, timeout_ms):
    validate_profile(profile)
    require(isinstance(artifact, dict) and set(artifact) == {"files"}, "invalid_patch")
    edits = artifact["files"]
    require(isinstance(edits, dict) and 0 < len(edits) <= 16 and
            set(edits) <= set(profile["editable"]), "forbidden_path")
    require(all(safe_path(p) and isinstance(text, str) and "\0" not in text for p, text in edits.items()), "invalid_patch")
    require(sum(len(text.encode("utf-8")) for text in edits.values()) <= MAX_EDIT, "patch_budget")
    patch = make_patch(profile["files"], edits)
    require(patch and len(patch.encode("utf-8")) <= MAX_EDIT * 2, "empty_or_large_patch")
    start = time.monotonic()
    deadline = start + timeout_ms / 1000
    manifest = profile["manifest"]
    measurements = []
    with tempfile.TemporaryDirectory(prefix="candidate-", dir=profile["workspace_root"]) as directory:
        os.chmod(directory, 0o755)
        for path, text in {**profile["files"], **edits}.items():
            destination = Path(directory) / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(text, encoding="utf-8", newline="")
            destination.chmod(profile["modes"].get(path, 0o644))
        for index, case in enumerate(profile["cases"]):
            if CANCELLED.is_set() or time.monotonic() >= deadline:
                break
            measured = run_case(directory, manifest, case, deadline, profile["owner"])
            measurements.append({"index": index, **measured})
    passed = (len(measurements) == len(profile["cases"]) and
              all(m["passed"] for m in measurements) and time.monotonic() < deadline and not CANCELLED.is_set())
    evidence = {"passed": passed, "tests_passed": sum(m["passed"] for m in measurements),
                "tests_total": len(profile["cases"]), "cases": measurements,
                "duration_ms": round((time.monotonic() - start) * 1000),
                "patch_bytes": len(patch.encode("utf-8")), "patch_sha256": hashlib.sha256(patch.encode("utf-8")).hexdigest(),
                "profile_sha256": manifest["profile_sha256"], "base_revision": manifest["base_revision"],
                "image": manifest["image"], "proposal_sha256": digest(edits),
                "candidate_sha256": digest({"files": {**profile["files"], **edits},
                    "modes": {**profile["modes"], **{p: profile["modes"].get(p, 0o644) for p in edits}}})}
    return {"files": edits, "patch": patch, "evaluation": evidence}


def watch_parent():
    # Parent keeps stdin open after sending its one JSONL request.
    while os.read(0, 4096):
        pass
    CANCELLED.set()


def main():
    line = sys.stdin.buffer.readline(2097153)
    require(line.endswith(b"\n") and len(line) <= 2097152, "input_budget")
    data = json.loads(line, object_pairs_hook=unique_object)
    threading.Thread(target=watch_parent, daemon=True).start()
    action = data["action"]
    if action == "prepare":
        result = prepare(data["config"])
    elif action == "evaluate":
        timeout = data["timeout_ms"]
        require(type(timeout) is int and 0 < timeout <= 120000, "invalid_timeout")
        result = evaluate(data["profile"], data["artifact"], timeout)
    else:
        raise Invalid("invalid_action")
    if CANCELLED.is_set():
        return
    print(json.dumps({"ok": True, "value": result}, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    try:
        main()
    except Invalid as error:
        print(json.dumps({"ok": False, "error": str(error)}), flush=True)
    except Exception:
        print(json.dumps({"ok": False, "error": "evaluation_failed"}), flush=True)
