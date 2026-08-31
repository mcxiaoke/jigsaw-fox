#!/usr/bin/env python3
"""Batch-generate jigsaw puzzle source images through the ComfyUI HTTP API.

Built for unattended overnight runs on a single consumer GPU (target: RTX 4070 12GB).
Standard library only - no pip install required.

Design notes:
  * Workflow comes from a user-exported ComfyUI "API format" JSON. The script never
    guesses node names; it only injects values into nodes it locates, so it keeps
    working across ComfyUI versions and model families (Z-Image / FLUX / SDXL).
  * Resume-safe. A JSON progress log records finished job keys; restarting skips them.
  * Prompts are generated with a deterministic RNG seeded by (tag, index, seed-base),
    so a resumed run reproduces the exact same prompt for an unfinished job.
  * VRAM hygiene: /free is called after every image, with a deeper clean every N images.
  * Ctrl+C finishes the in-flight image, then exits cleanly. Nothing is lost.

Usage:
    python scripts/comfyui_batch_gen.py --list-tags
    python scripts/comfyui_batch_gen.py --workflow wf_api.json --dry-run --dry-run-count 5
    python scripts/comfyui_batch_gen.py --workflow wf_api.json --comfyui-root D:/ComfyUI --out D:/jigsaw_raw
    python scripts/comfyui_batch_gen.py --workflow wf_api.json --tags Nature,Flowers --per-tag 20
    python scripts/comfyui_batch_gen.py --workflow wf_api.json --resume --out D:/jigsaw_raw
"""

from __future__ import annotations

import argparse
import json
import random
import shutil
import signal
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

PROGRESS_NAME = "_progress.json"
METADATA_DIR = "_metadata"
STAGING_SUBDIR = "jig"

_stop_requested = False


def _on_sigint(signum, frame):
    global _stop_requested
    if _stop_requested:
        print("\n[abort] second interrupt, exiting immediately")
        sys.exit(130)
    _stop_requested = True
    print("\n[stop] interrupt received, finishing current image then exiting ...")


# ---------------------------------------------------------------------------
# ComfyUI client
# ---------------------------------------------------------------------------


class ComfyError(RuntimeError):
    pass


class ComfyStuck(ComfyError):
    """ComfyUI process is alive over HTTP but no longer making progress (driver hang)."""


class ComfyClient:
    def __init__(self, host: str, timeout: float = 120.0):
        self.base = host.rstrip("/")
        self.timeout = timeout

    def _request(self, method: str, path: str, payload=None, timeout: float | None = None):
        data = None
        headers = {}
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.base + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=timeout or self.timeout) as resp:
                raw = resp.read().decode("utf-8")
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            raise ComfyError(f"HTTP {e.code} on {method} {path}: {body[:600]}") from e
        except urllib.error.URLError as e:
            raise ComfyError(f"cannot reach {self.base}{path}: {e.reason}") from e

    def queue_prompt(self, workflow: dict) -> str:
        res = self._request("POST", "/prompt", {"prompt": workflow})
        if "prompt_id" not in res:
            raise ComfyError(f"unexpected /prompt response: {str(res)[:400]}")
        return res["prompt_id"]

    def history(self, prompt_id: str, timeout: float | None = None):
        res = self._request("GET", f"/history/{prompt_id}", timeout=timeout)
        return res.get(prompt_id)

    def free(self, unload_models: bool = True) -> None:
        self._request("POST", "/free", {"unload_models": unload_models, "free_memory": True})

    def alive(self, probe_timeout: float = 5.0) -> bool:
        """Lightweight liveness probe. False means the HTTP server stopped answering,
        which on Windows usually means the CUDA driver / ComfyUI process is hung."""
        try:
            self._request("GET", "/system_stats", timeout=probe_timeout)
            return True
        except ComfyError:
            return False


def wait_for_image(client: ComfyClient, prompt_id: str, total_timeout: float,
                   stuck_timeout: float, poll: float) -> dict:
    """Poll /history until the image is done, with hang detection.

    Raises ComfyStuck as soon as the job exceeds stuck_timeout AND the server
    has stopped answering, so a driver hang does not burn the full timeout.
    """
    t0 = time.time()
    warned = False
    while time.time() - t0 < total_timeout:
        try:
            h = client.history(prompt_id, timeout=max(10.0, poll * 8))
        except ComfyError:
            if not client.alive():
                raise ComfyStuck(
                    f"ComfyUI stopped responding after {time.time() - t0:.0f}s "
                    f"(likely driver hang)"
                )
            raise
        if h is not None:
            return h
        if not warned and (time.time() - t0) > stuck_timeout:
            warned = True
            print(f"  [slow] {time.time() - t0:.0f}s without result, probing ComfyUI ...")
            if not client.alive():
                raise ComfyStuck(f"ComfyUI hung after {time.time() - t0:.0f}s")
        time.sleep(poll)
    raise ComfyError(f"timeout after {total_timeout:.0f}s waiting for {prompt_id}")


# ---------------------------------------------------------------------------
# Workflow node discovery and injection
# ---------------------------------------------------------------------------

PROMPT_CLASSES = {
    "CLIPTextEncode",
    "TextEncodeQwenImage",
    "TextEncodeZImage",
    "TextEncodeFlux",
    "CLIPTextEncodeFlux",
}
SEED_CLASSES = {"KSampler", "KSamplerAdvanced", "SamplerCustom", "SamplerCustomAdvanced", "RandomNoise"}
SIZE_CLASSES = {"EmptyLatentImage", "EmptySD3LatentImage", "EmptyLatentImageCustom", "EmptyFlux2LatentImage"}
OUTPUT_CLASSES = {"SaveImage", "ImageSave", "SaveImageWithMetadata"}


def _title_of(node: dict) -> str:
    return str(node.get("_meta", {}).get("title", "")).lower()


def _find(workflow: dict, classes: set, title_keywords: tuple, requires: tuple) -> str | None:
    """Locate a node id. Title keyword match wins over class match."""
    for node_id, node in workflow.items():
        if not isinstance(node, dict) or "inputs" not in node:
            continue
        title = _title_of(node)
        if any(k in title for k in title_keywords):
            if all(r in node["inputs"] for r in requires):
                return node_id
    for node_id, node in workflow.items():
        if not isinstance(node, dict) or node.get("class_type") not in classes:
            continue
        if all(r in node["inputs"] for r in requires):
            return node_id
    return None


def detect_nodes(workflow: dict) -> dict:
    found = {
        "prompt": _find(workflow, PROMPT_CLASSES, ("prompt", "positive"), ("text",)),
        "seed": _find(workflow, SEED_CLASSES, ("seed", "noise"), ("seed",)),
        "size": _find(workflow, SIZE_CLASSES, ("size", "latent", "empty"), ("width", "height")),
        "output": _find(workflow, OUTPUT_CLASSES, ("save", "output"), ("filename_prefix",)),
    }
    missing = [k for k, v in found.items() if v is None]
    if missing:
        raise ComfyError(
            "could not locate node(s): "
            + ", ".join(missing)
            + ". Name the nodes in ComfyUI (title containing 'prompt', 'seed', 'size', 'save'), "
            "or pass explicit ids via --prompt-node / --seed-node / --size-node / --output-node."
        )
    return found


def inject_workflow(template: dict, node_ids: dict, prompt: str, seed: int, w: int, h: int,
                    out_prefix: str, steps: int | None, cfg: float | None) -> dict:
    wf = json.loads(json.dumps(template))
    wf[node_ids["prompt"]]["inputs"]["text"] = prompt
    wf[node_ids["seed"]]["inputs"]["seed"] = seed
    wf[node_ids["size"]]["inputs"]["width"] = w
    wf[node_ids["size"]]["inputs"]["height"] = h
    wf[node_ids["output"]]["inputs"]["filename_prefix"] = out_prefix
    seed_inputs = wf[node_ids["seed"]]["inputs"]
    if steps is not None and "steps" in seed_inputs:
        seed_inputs["steps"] = steps
    if cfg is not None and "cfg" in seed_inputs:
        seed_inputs["cfg"] = cfg
    return wf


# ---------------------------------------------------------------------------
# Jobs
# ---------------------------------------------------------------------------


@dataclass
class Job:
    key: str
    tag: str
    index: int
    prompt: str
    seed: int
    ratio: str
    width: int
    height: int
    attempts: int = 0


@dataclass
class Stats:
    done: int = 0
    failed: int = 0
    skipped: int = 0
    durations: list = field(default_factory=list)

    def eta_text(self, remaining: int) -> str:
        if not self.durations or remaining <= 0:
            return "--"
        avg = sum(self.durations[-30:]) / len(self.durations[-30:])
        secs = avg * remaining
        h, rem = divmod(int(secs), 3600)
        m, s = divmod(rem, 60)
        return f"{h}h{m:02d}m" if h else f"{m}m{s:02d}s"


def build_jobs(lib: dict, tag_filter: list[str] | None, per_tag: int | None,
               seed_base: int, rounds: int | None = None,
               batch_per_tag: int = 4) -> list[Job]:
    """Build the job list.

    Diversity strategy:
    * Subject is selected by ROTATION (`subjects[i % len]`) instead of random draw,
      so every consecutive run of len(subjects) images covers all distinct scenes,
      then the cycle repeats for the next "round" (each round draws a new seed and
      a new lighting/viewpoint/detail/atmosphere combination per subject).
      Prompt-stable across resume runs because i is deterministic per tag.
    * Lighting / viewpoint / detail / atmosphere are drawn from a per-job RNG seeded
      by (tag, index, seed_base), so a resumed job reproduces the exact same prompt.

    Image count per tag (priority):
      1. rounds is set  -> len(subjects) * rounds  (draw N cards per subject)
      2. per_tag is set -> per_tag
      3. otherwise      -> tag quota from the library
    """
    ratios = lib["ratios"]
    jobs: list[Job] = []
    for tag in lib["tags"]:
        tag_id = tag["id"]
        if tag_filter and tag_id not in tag_filter:
            continue
        subjects = tag["subjects"]
        if rounds is not None:
            count = len(subjects) * rounds
        elif per_tag:
            count = per_tag
        else:
            count = int(tag.get("quota", 100))

        for i in range(count):
            rng = random.Random(f"{tag_id}:{i}:{seed_base}")
            subject = subjects[i % len(subjects)]
            ratio = rng.choice(tag["ratios"])
            parts = [subject]
            if tag.get("extra"):
                parts.append(tag["extra"])
            parts.append(rng.choice(lib["modifiers"]["lighting"]))
            parts.append(rng.choice(lib["modifiers"]["viewpoint"]))
            for key in ("style", "detail", "atmosphere"):
                if key in lib["modifiers"]:
                    parts.append(rng.choice(lib["modifiers"][key]))
            parts.append(lib["quality_suffix"])
            prompt = ", ".join(p.strip() for p in parts if p.strip())
            dim = ratios[ratio]
            jobs.append(
                Job(
                    key=f"{tag_id}:{i:04d}",
                    tag=tag_id,
                    index=i,
                    prompt=prompt,
                    seed=rng.randrange(0, 2**32 - 1),
                    ratio=ratio,
                    width=int(dim["width"]),
                    height=int(dim["height"]),
                )
            )
    if batch_per_tag and batch_per_tag > 1:
        # Round-robin scheduling: interleave tags so every tag gets a batch before
        # any tag gets its next batch. Without this, an interrupted run leaves the
        # last tags with zero images while early tags have hundreds.
        tag_order = {t["id"]: i for i, t in enumerate(lib["tags"])}
        jobs.sort(key=lambda j: (j.index // batch_per_tag, tag_order.get(j.tag, 999), j.index))
    return jobs


def load_progress(path: Path) -> dict:
    if path.exists():
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            print(f"[warn] progress file unreadable, starting fresh: {path}")
    return {"done": [], "failed": []}


def save_progress(path: Path, progress: dict) -> None:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(progress, ensure_ascii=False, indent=1), encoding="utf-8")
    tmp.replace(path)


def collect_images(history: dict) -> list[dict]:
    images: list[dict] = []
    for node_out in history.get("outputs", {}).values():
        for img in node_out.get("images", []):
            images.append(img)
    return images


def relocate(src_root: Path | None, images: list[dict], out_dir: Path, job: Job) -> str:
    """Move generated files out of ComfyUI output dir into the tag folder."""
    if not src_root or not images:
        return images[0]["filename"] if images else ""
    dst_dir = out_dir / job.tag
    dst_dir.mkdir(parents=True, exist_ok=True)
    names = []
    for n, img in enumerate(images):
        sub = Path(img.get("subfolder", ""))
        src = src_root / "output" / sub / img["filename"]
        if not src.exists():
            continue
        suffix = src.suffix or ".png"
        stem = f"{job.tag}_{job.index:04d}_{job.seed}_{job.width}x{job.height}"
        dst = dst_dir / f"{stem}{'' if len(images) == 1 else f'_{n}'}{suffix}"
        shutil.move(str(src), str(dst))
        names.append(dst.name)
    return ",".join(names) if names else ""


def append_metadata(out_dir: Path, job: Job, filename: str, model: str, steps, cfg) -> None:
    meta_dir = out_dir / METADATA_DIR
    meta_dir.mkdir(parents=True, exist_ok=True)
    record = {
        "key": job.key,
        "tag": job.tag,
        "index": job.index,
        "seed": job.seed,
        "ratio": job.ratio,
        "width": job.width,
        "height": job.height,
        "prompt": job.prompt,
        "filename": filename,
        "model": model,
        "steps": steps,
        "cfg": cfg,
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    with (meta_dir / f"{job.tag}.jsonl").open("a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def parse_args(argv=None):
    p = argparse.ArgumentParser(
        description="Batch generate jigsaw puzzle images via ComfyUI API.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--library", default=str(Path(__file__).with_name("my_prompt_library.json")),
                   help="prompt library JSON (default: alongside this script)")
    p.add_argument("--workflow", help="ComfyUI workflow exported in API format (JSON)")
    p.add_argument("--host", default="http://127.0.0.1:8188", help="ComfyUI HTTP address")
    p.add_argument("--comfyui-root", help="ComfyUI install root, needed to move files out of its output dir")
    p.add_argument("--out", default="jigsaw_raw", help="output directory")
    p.add_argument("--tags", help="comma separated tag ids to restrict the run")
    p.add_argument("--per-tag", type=int, help="override image count per tag (good for smoke tests)")
    p.add_argument("--seed-base", type=int, default=20260830, help="base seed, changing it reshuffles every prompt")
    p.add_argument("--steps", type=int, help="override sampler steps (8 for Z-Image Turbo, 4 for FLUX Klein)")
    p.add_argument("--cfg", type=float, help="override CFG (1.0 for distilled turbo models)")
    p.add_argument("--poll", type=float, default=1.0, help="history poll interval in seconds")
    p.add_argument("--timeout", type=float, default=300.0, help="per-image timeout in seconds")
    p.add_argument("--retries", type=int, default=2, help="retries per failed image")
    p.add_argument("--hard-reset-minutes", type=float, default=10.0,
                   help="unload models AND free VRAM every N minutes. Prevents the "
                        "fragmentation/leak buildup that hangs the driver on long runs.")
    p.add_argument("--stuck-timeout", type=float, default=90.0,
                   help="seconds without a result before probing ComfyUI for a hang "
                        "(normal image is ~16s)")
    p.add_argument("--max-stuck", type=int, default=3,
                   help="abort after N consecutive hung images (progress stays saved)")
    p.add_argument("--clean-every", type=int, default=100, help="deep VRAM clean every N images")
    p.add_argument("--batch-per-tag", type=int, default=4,
                   help="images per tag per scheduling round. Tags are interleaved so "
                        "one round = every tag gets this many images. Use 0 to disable "
                        "interleaving (old behaviour: finish one tag before the next).")
    p.add_argument("--rounds", type=int,
                   help="draw N cards per subject, overriding quota/per-tag. "
                        "total = sum(subjects per tag) * N. "
                        "Example: --rounds 10 draws 10 variants of every scene.")
    p.add_argument("--sec-per-image", type=float, default=16.0,
                   help="assumed seconds per image for the ETA display. "
                        "RTX 4070 fp8 measured: ~16s with distinct prompts (12.2s only "
                        "when ComfyUI can cache identical conditioning)")
    p.add_argument("--no-resume", action="store_true", help="ignore existing progress and regenerate everything")
    p.add_argument("--dry-run", action="store_true", help="print planned prompts, do not call ComfyUI")
    p.add_argument("--dry-run-count", type=int, default=5, help="how many dry-run prompts to print")
    p.add_argument("--list-tags", action="store_true", help="list tags and quotas then exit")
    p.add_argument("--prompt-node", help="explicit node id for prompt injection")
    p.add_argument("--seed-node", help="explicit node id for seed injection")
    p.add_argument("--size-node", help="explicit node id for width/height injection")
    p.add_argument("--output-node", help="explicit node id for the save node")
    return p.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    signal.signal(signal.SIGINT, _on_sigint)

    lib_path = Path(args.library)
    if not lib_path.exists():
        print(f"[fatal] prompt library not found: {lib_path}")
        return 2
    lib = json.loads(lib_path.read_text(encoding="utf-8"))

    if args.list_tags:
        total = 0
        print(f"{'tag':<16}{'tier':<6}{'quota':>7}   zh")
        for t in lib["tags"]:
            q = int(t.get("quota", 0))
            total += q
            print(f"{t['id']:<16}{t.get('tier', '-'):<6}{q:>7}   {t.get('zh', '')}")
        print(f"{'TOTAL':<16}{'':<6}{total:>7}")
        return 0

    if not args.workflow:
        print("[fatal] --workflow is required (ComfyUI: menu -> Save (API Format))")
        return 2

    tpl = json.loads(Path(args.workflow).read_text(encoding="utf-8"))
    node_ids = detect_nodes(tpl)
    for override, key in (
        (args.prompt_node, "prompt"),
        (args.seed_node, "seed"),
        (args.size_node, "size"),
        (args.output_node, "output"),
    ):
        if override:
            if override not in tpl:
                print(f"[fatal] node id '{override}' not present in workflow")
                return 2
            node_ids[key] = override

    tag_filter = [t.strip() for t in args.tags.split(",")] if args.tags else None
    jobs = build_jobs(lib, tag_filter, args.per_tag, args.seed_base, args.rounds,
                      args.batch_per_tag)
    if not jobs:
        print("[fatal] no jobs produced, check --tags spelling")
        return 2

    steps = args.steps if args.steps is not None else lib.get("generation", {}).get("steps")
    cfg = args.cfg if args.cfg is not None else lib.get("generation", {}).get("cfg")
    model_hint = lib.get("model_hint", "unknown")

    est_hours = len(jobs) * args.sec_per_image / 3600
    if args.rounds:
        print(f"[plan] {len(jobs)} jobs ({args.rounds} cards x {len({j.tag for j in jobs})} tags), "
              f"estimated ~{est_hours:.1f}h at {args.sec_per_image}s/img")
    else:
        print(f"[plan] {len(jobs)} jobs, estimated ~{est_hours:.1f}h at {args.sec_per_image}s/img")
    print(f"[plan] steps={steps}, cfg={cfg}, ratios={sorted({j.ratio for j in jobs})}")
    print(f"[plan] nodes prompt={node_ids['prompt']} seed={node_ids['seed']} "
          f"size={node_ids['size']} save={node_ids['output']}")

    if args.dry_run:
        for j in jobs[: args.dry_run_count]:
            print(f"\n--- {j.key} [{j.ratio} {j.width}x{j.height}] seed={j.seed}")
            print(j.prompt)
        print(f"\n[dry-run] {len(jobs)} jobs planned, nothing generated")
        return 0

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    comfy_root = Path(args.comfyui_root) if args.comfyui_root else None
    progress_path = out_dir / PROGRESS_NAME
    progress = {"done": [], "failed": []} if args.no_resume else load_progress(progress_path)
    done_set = set(progress["done"])

    client = ComfyClient(args.host)
    stats = Stats()
    total = len(jobs)
    last_hard_reset = time.time()
    consecutive_stuck = 0

    print(f"[run] output -> {out_dir.resolve()}")
    print(f"[run] resuming: {len(done_set)} already done")
    print(f"[run] hard reset every {args.hard_reset_minutes:g} min, "
          f"hang probe at {args.stuck_timeout:.0f}s, abort after {args.max_stuck} hangs\n")

    for pos, job in enumerate(jobs, start=1):
        if _stop_requested:
            break
        if job.key in done_set:
            stats.skipped += 1
            continue

        wf = inject_workflow(tpl, node_ids, job.prompt, job.seed, job.width, job.height,
                             f"{STAGING_SUBDIR}/{job.tag}_{job.index:04d}", steps, cfg)
        t0 = time.time()
        ok = False
        last_err = ""
        hung = False
        for attempt in range(args.retries + 1):
            try:
                pid = client.queue_prompt(wf)
                history = wait_for_image(client, pid, args.timeout, args.stuck_timeout, args.poll)
                images = collect_images(history)
                filename = relocate(comfy_root, images, out_dir, job)
                if not filename:
                    last_err = "no image file found in output dir (check --comfyui-root)"
                    raise ComfyError(last_err)
                ok = True
                break
            except ComfyStuck as e:
                # Driver-level hang: retrying immediately is pointless and dangerous.
                last_err = str(e)
                hung = True
                break
            except ComfyError as e:
                last_err = str(e)
                if attempt < args.retries:
                    print(f"[retry] {job.key} attempt {attempt + 1}/{args.retries}: {last_err[:160]}")
                    time.sleep(3)
                    try:
                        client.free()
                    except ComfyError:
                        pass

        elapsed = time.time() - t0
        if ok:
            consecutive_stuck = 0
            append_metadata(out_dir, job, filename, model_hint, steps, cfg)
            progress["done"].append(job.key)
            done_set.add(job.key)
            stats.done += 1
            stats.durations.append(elapsed)
            print(f"[{time.strftime('%H:%M:%S')}] [{stats.done + stats.skipped:>5}/{total}] "
                  f"{job.tag:<16} {job.ratio} {job.seed:>10} {elapsed:5.1f}s  eta {stats.eta_text(total - stats.done - stats.skipped)}")
        else:
            progress["failed"].append({"key": job.key, "error": last_err[:400], "ts": time.strftime("%H:%M:%S")})
            stats.failed += 1
            print(f"[{time.strftime('%H:%M:%S')}] [ FAIL ] {job.key}: {last_err[:160]}")
            if hung:
                consecutive_stuck += 1
                print(f"[hang] {job.key} — ComfyUI/driver unresponsive. "
                      f"Restart ComfyUI and re-run this command to resume.")
                if consecutive_stuck >= args.max_stuck:
                    save_progress(progress_path, progress)
                    print(f"\n[fatal] {consecutive_stuck} consecutive hangs — aborting to avoid a "
                          f"system freeze.\n"
                          f"        Progress is saved ({len(progress['done'])} done).\n"
                          f"        Restart ComfyUI, then re-run the same command to resume.")
                    return 1

        # NOTE: no per-image /free here. On ComfyUI 0.34 (DynamicVRAM + aimdo +
        # RAM pressure cache) a per-image /free evicts the resident TE/UNET/VAE,
        # forcing a full ~7s reload on every image (12.2s -> ~19s measured).
        # Models stay resident; only the periodic hard reset below runs.
        if (time.time() - last_hard_reset) > args.hard_reset_minutes * 60:
            try:
                client.free(unload_models=True)
                print(f"[{time.strftime('%H:%M:%S')}] [maint] periodic hard reset "
                      f"({args.hard_reset_minutes:g} min) — models unloaded")
            except ComfyError as e:
                print(f"[{time.strftime('%H:%M:%S')}] [maint] hard reset failed: {str(e)[:120]}")
            last_hard_reset = time.time()

        if stats.done % args.clean_every == 0 and stats.done > 0:
            try:
                client.free(unload_models=True)
            except ComfyError:
                pass
            print(f"[maint] deep VRAM clean after {stats.done} images")

        if stats.done % 10 == 0 or not ok:
            save_progress(progress_path, progress)

    save_progress(progress_path, progress)
    print("\n[done] summary")
    print(f"  generated : {stats.done}")
    print(f"  skipped   : {stats.skipped} (already present)")
    print(f"  failed    : {stats.failed}")
    if stats.durations:
        avg = sum(stats.durations) / len(stats.durations)
        print(f"  avg time  : {avg:.1f}s/image")
    print(f"  output    : {out_dir.resolve()}")
    print(f"  metadata  : {out_dir / METADATA_DIR}")
    if progress["failed"]:
        print(f"  retry failures with:  python {Path(__file__).name} --resume --out {args.out} ...")
    return 0


if __name__ == "__main__":
    sys.exit(main())
