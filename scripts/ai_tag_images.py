#!/usr/bin/env python3
"""
Batch classify jigsaw puzzle images with local Ollama Qwen3-VL.

Default:
    - Model: qwen3-vl:4b
    - Batch size: 4 images/request
    - Output: tags.json
    - Incremental/resumable
    - Exactly ONE primary tag per image
    - Fixed 21-tag taxonomy

Usage:
    pip install ollama
    ollama pull qwen3-vl:4b

    python tag_images_batch.py ./images
    python tag_images_batch.py ./images --output tags.json
    python tag_images_batch.py ./images --model qwen3-vl:4b --batch-size 4
    python tag_images_batch.py ./images --force

The script:
    1. Recursively scans images.
    2. Uses SHA-1 to detect unchanged images.
    3. Sends up to N images per Ollama request.
    4. Validates that every returned item has exactly one allowed tag.
    5. Saves tags.json after every successful batch.
    6. Prints category statistics at the end.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from pathlib import Path
from typing import Any

try:
    from ollama import chat
except ImportError:
    print("Missing dependency: ollama")
    print("Install with: pip install ollama")
    sys.exit(1)


# ---------------------------------------------------------------------------
# Fixed taxonomy: DO NOT let the model invent tags.
# ---------------------------------------------------------------------------

TAGS = [
    "Animals",
    "Pets",
    "Nature",
    "Landscapes",
    "Flowers",
    "Ocean",
    "Birds",
    "Cities",
    "Architecture",
    "Food",
    "Art",
    "Fantasy",
    "Space",
    "Transportation",
    "People",
    "Sports",
    "Seasons",
    "Holidays",
    "Abstract",
    "Cartoon",
    "Others",
]

TAG_DESCRIPTIONS = {
    "Animals": "野生动物、动物群、动物自然场景；不含家庭宠物和鸟类",
    "Pets": "猫、狗、兔子、仓鼠等家庭宠物",
    "Nature": "森林、植物、自然生态、自然元素",
    "Landscapes": "山川、湖泊、田野、峡谷等宏观景观",
    "Flowers": "花朵、花束、花田、园艺植物",
    "Ocean": "海洋、海滩、海浪、水下、海洋生态",
    "Birds": "鹰、猫头鹰、鹦鹉、火烈鸟等鸟类",
    "Cities": "城市街景、城市生活、城市天际线",
    "Architecture": "建筑本体、住宅、教堂、桥梁、城堡，以及著名地标",
    "Food": "食物、甜点、料理、餐桌、美食摄影",
    "Art": "绘画、艺术作品、艺术风格、经典名画",
    "Fantasy": "魔法、龙、独角兽、精灵、幻想世界",
    "Space": "宇宙、星球、银河、宇航员",
    "Transportation": "汽车、飞机、火车、轮船、自行车等",
    "People": "人像、人物活动、人物生活场景",
    "Sports": "足球、篮球、网球、滑雪等运动",
    "Seasons": "春、夏、秋、冬及明显季节场景",
    "Holidays": "圣诞节、万圣节、复活节、新年等明确节日主题",
    "Abstract": "抽象艺术、几何图案、纹理、非具象视觉",
    "Cartoon": "卡通、动漫风、漫画、儿童插画",
    "Others": "无法稳定归入上述主题的小众内容",
}


IMAGE_EXTENSIONS = {
    ".jpg", ".jpeg", ".png", ".webp",
    ".bmp", ".gif", ".tif", ".tiff"
}


SYSTEM_PROMPT = r"""
You are a strict image classifier for a jigsaw puzzle application.

Your task is to assign EXACTLY ONE primary tag to EACH provided image.

You MUST select the tag from the allowed 21-category taxonomy below.
You MUST NOT create new tags.
You MUST NOT return multiple tags for an image.
You MUST preserve the requested image IDs exactly.

The classification should answer:
"What is the main theme that a jigsaw puzzle user would most likely use
to find/filter this image?"

Allowed tags and definitions:

1. Animals
   Wild animals, groups of animals, animals in natural settings.
   DO NOT use for domestic pets or birds.

2. Pets
   Domestic companion animals such as cats, dogs, rabbits, hamsters, etc.

3. Nature
   Forests, plants, natural ecosystems, trees, waterfalls, and natural elements.

4. Landscapes
   Panoramic or scenic views such as mountains, lakes, valleys,
   countryside, cliffs, and broad scenic views.

5. Flowers
   Flowers, bouquets, flower fields, gardens where flowers are the
   primary visual subject, and floral arrangements.

6. Ocean
   Ocean, sea, beach, waves, underwater scenes, coral reefs,
   and marine environments.

7. Birds
   Birds such as eagles, owls, parrots, flamingos, swans, peacocks, etc.

8. Cities
   Urban streets, city life, downtown scenes, city skylines, and urban scenery.

9. Architecture
   Buildings and structures such as houses, churches, bridges, castles,
   mansions, towers, and other architecture, INCLUDING famous landmarks.
   There is NO separate Landmarks tag in this taxonomy.

10. Food
    Food, desserts, dishes, fruit, drinks, tables of food, food photography.

11. Art
    Paintings, artworks, fine-art compositions, classic paintings,
    and artistic works where the artwork itself is the subject.

12. Fantasy
    Dragons, unicorns, fairies, magic, mythical creatures,
    fantasy worlds, and clearly fantastical subjects.

13. Space
    Outer space, planets, galaxies, nebulae, stars, astronauts, spacecraft.

14. Transportation
    Cars, airplanes, trains, ships, boats, bicycles, motorcycles,
    buses, trams, and other transportation.

15. People
    Portraits, groups of people, people-centered activities,
    lifestyle scenes, and human subjects.
    Prefer Sports, Space, Holidays, etc. when those themes are clearly dominant.

16. Sports
    Clearly recognizable sports or sporting activities such as football,
    basketball, tennis, skiing, golf, surfing, running, etc.

17. Seasons
    Spring, summer, autumn, winter, or a scene whose main appeal is
    a clearly recognizable season.

18. Holidays
    Explicit holiday themes such as Christmas, Halloween, Easter,
    New Year, Valentine's Day, Thanksgiving, Lunar New Year, etc.

19. Abstract
    Non-representational art, geometric patterns, textures, mandalas,
    shapes, and abstract compositions.

20. Cartoon
    Cartoon, anime-style, comic, children's illustration, and
    character illustration when the illustration style is the main theme.

21. Others
    A small niche theme that cannot reasonably and stably fit the above categories.

IMPORTANT CONFLICT RULES:

A. Main subject beats background.
   A large cat in a beach scene -> Pets, not Ocean.
   A large eagle in a mountain scene -> Birds, not Landscapes.
   A large car in a city -> Transportation, not Cities.

B. Birds have their own category.
   A bird as the main subject -> Birds.

C. Pets have their own category.
   Domestic cat/dog/rabbit/hamster as the main subject -> Pets.

D. Famous landmarks belong to Architecture.
   Eiffel Tower -> Architecture.
   Big Ben -> Architecture.
   Great Wall -> Architecture.
   Taj Mahal -> Architecture.

E. Nature vs Landscapes:
   Forest, trees, plants, waterfalls, natural ecosystem -> Nature.
   Broad scenic mountain/lake/valley/countryside view -> Landscapes.

F. Ocean:
   Beach, sea, waves, underwater, coral reef, marine environment -> Ocean.
   A tiny boat inside a broad beach scene does NOT make it Transportation.

G. Seasons requires clear seasonal evidence.
   Autumn leaves across the scene -> Seasons.
   A normal forest with only a few yellow leaves -> Nature or Landscapes.
   Do not infer Seasons merely from color.

H. Holidays requires explicit recognizable holiday evidence.
   Christmas tree / Santa / Halloween pumpkins -> Holidays.
   A warm fireplace without holiday symbols -> not Holidays.

I. Art vs Cartoon vs Abstract:
   A recognizable painting/artwork -> Art.
   A clearly cartoon/anime/comic illustration -> Cartoon.
   A non-representational geometric/pattern composition -> Abstract.

J. Fantasy:
   Clearly mythical/fantasy content -> Fantasy.
   A real animal illustrated in a fantasy-looking style is NOT automatically Fantasy.

K. Use Others sparingly.
   Do not use Others simply because two categories are close.
   Choose the best category when a reasonable choice exists.

VERY IMPORTANT:
- Do not classify based only on color palette.
- Do not classify based only on aesthetic/mood.
- Do not invent categories.
- Do not use text in the image as the sole reason for classification.
- Return one result for every input image.
- Output valid JSON only.
""".strip()


def build_schema(batch_size: int) -> dict[str, Any]:
    return {
        "type": "object",
        "properties": {
            "results": {
                "type": "array",
                "minItems": batch_size,
                "maxItems": batch_size,
                "items": {
                    "type": "object",
                    "properties": {
                        "image_id": {"type": "string"},
                        "tag": {"type": "string", "enum": TAGS},
                        "confidence": {
                            "type": "number",
                            "minimum": 0,
                            "maximum": 1,
                        },
                        "subject": {"type": "string"},
                        "scene": {"type": "string"},
                        "reason": {"type": "string"},
                    },
                    "required": [
                        "image_id",
                        "tag",
                        "confidence",
                        "subject",
                        "scene",
                        "reason",
                    ],
                },
            }
        },
        "required": ["results"],
    }


def sha1_file(path: Path, chunk_size: int = 1024 * 1024) -> str:
    h = hashlib.sha1()
    with path.open("rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def scan_images(input_dir: Path) -> list[Path]:
    return sorted(
        p for p in input_dir.rglob("*")
        if p.is_file() and p.suffix.lower() in IMAGE_EXTENSIONS
    )


def load_results(output_path: Path) -> list[dict[str, Any]]:
    if not output_path.exists():
        return []

    try:
        data = json.loads(output_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        print(f"ERROR: Cannot parse {output_path}: {e}")
        print("Please fix or remove the file before continuing.")
        sys.exit(1)

    if not isinstance(data, list):
        print(f"ERROR: {output_path} must contain a JSON array.")
        sys.exit(1)

    return data


def save_results(output_path: Path, results: list[dict[str, Any]]) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = output_path.with_suffix(output_path.suffix + ".tmp")

    tmp.write_text(
        json.dumps(results, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    tmp.replace(output_path)


def make_indexes(
    results: list[dict[str, Any]],
) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    by_path: dict[str, dict[str, Any]] = {}
    by_sha1: dict[str, dict[str, Any]] = {}

    for item in results:
        if item.get("path"):
            by_path[item["path"]] = item
        if item.get("sha1"):
            by_sha1[item["sha1"]] = item

    return by_path, by_sha1


def validate_batch_response(
    data: dict[str, Any],
    expected_ids: list[str],
) -> dict[str, dict[str, Any]]:
    if not isinstance(data, dict) or not isinstance(data.get("results"), list):
        raise ValueError("Model response does not contain a 'results' array.")

    results = data["results"]

    if len(results) != len(expected_ids):
        raise ValueError(
            f"Expected {len(expected_ids)} results, received {len(results)}."
        )

    indexed: dict[str, dict[str, Any]] = {}

    for item in results:
        if not isinstance(item, dict):
            raise ValueError("A result item is not an object.")

        image_id = item.get("image_id")
        tag = item.get("tag")

        if image_id not in expected_ids:
            raise ValueError(f"Unexpected image_id returned: {image_id!r}")

        if image_id in indexed:
            raise ValueError(f"Duplicate image_id returned: {image_id!r}")

        if tag not in TAGS:
            raise ValueError(f"Invalid tag returned for {image_id}: {tag!r}")

        confidence = float(item.get("confidence", 0))
        if not 0 <= confidence <= 1:
            raise ValueError(
                f"Invalid confidence for {image_id}: {confidence!r}"
            )

        item["confidence"] = confidence
        indexed[image_id] = item

    missing = [image_id for image_id in expected_ids if image_id not in indexed]
    if missing:
        raise ValueError(f"Missing results for image IDs: {missing}")

    return indexed


def classify_batch(
    image_paths: list[Path],
    relative_paths: list[str],
    model: str,
    retries: int,
) -> dict[str, dict[str, Any]]:

    # Use stable per-batch IDs so the model can associate each image with a result.
    image_ids = [f"img_{i+1}" for i in range(len(image_paths))]
    schema = build_schema(len(image_paths))

    user_content_lines = [
        "Classify the following images.",
        "Return EXACTLY one result for every image.",
        "",
    ]

    for image_id, rel_path in zip(image_ids, relative_paths):
        user_content_lines.append(f"{image_id}: {rel_path}")

    user_content = "\n".join(user_content_lines)

    last_error: Exception | None = None

    for attempt in range(retries + 1):
        try:
            response = chat(
                model=model,
                messages=[
                    {
                        "role": "system",
                        "content": SYSTEM_PROMPT,
                    },
                    {
                        "role": "user",
                        "content": user_content,
                        "images": [str(p.resolve()) for p in image_paths],
                    },
                ],
                format=schema,
                options={
                    "temperature": 0,
                },
            )

            raw = response.message.content
            data = json.loads(raw)
            return validate_batch_response(data, image_ids)

        except Exception as e:
            last_error = e

            if attempt < retries:
                # A little delay helps transient Ollama/model errors.
                sleep_seconds = 2 ** attempt
                print(
                    f"    Batch failed: {e}\n"
                    f"    Retrying in {sleep_seconds}s "
                    f"({attempt + 1}/{retries})..."
                )
                time.sleep(sleep_seconds)

    raise RuntimeError(str(last_error))


def make_stats(results: list[dict[str, Any]]) -> dict[str, int]:
    stats = {tag: 0 for tag in TAGS}
    for item in results:
        tag = item.get("tag")
        if tag in stats:
            stats[tag] += 1
    return stats


def print_stats(results: list[dict[str, Any]]) -> None:
    stats = make_stats(results)

    print("\nCategory statistics")
    print("-" * 32)

    max_label = max(len(tag) for tag in TAGS)

    for tag in TAGS:
        print(f"{tag:<{max_label}}  {stats[tag]:>5}")

    review_count = sum(
        1 for item in results if item.get("review_required") is True
    )

    print("-" * 32)
    print(f"{'Total':<{max_label}}  {len(results):>5}")
    print(f"{'Review':<{max_label}}  {review_count:>5}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Batch classify jigsaw puzzle images with local Ollama Qwen3-VL."
    )

    parser.add_argument(
        "input_dir",
        type=Path,
        help="Directory containing images; subdirectories are scanned recursively.",
    )

    parser.add_argument(
        "--output",
        type=Path,
        default=Path("tags.json"),
        help="Output JSON path (default: tags.json).",
    )

    parser.add_argument(
        "--model",
        default="qwen3-vl:4b",
        help="Ollama vision model (default: qwen3-vl:4b).",
    )

    parser.add_argument(
        "--batch-size",
        type=int,
        default=4,
        choices=range(1, 9),
        metavar="{1..8}",
        help="Images per request (default: 4).",
    )

    parser.add_argument(
        "--retries",
        type=int,
        default=2,
        help="Retries per failed batch (default: 2).",
    )

    parser.add_argument(
        "--force",
        action="store_true",
        help="Reprocess all images instead of skipping unchanged images.",
    )

    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if not args.input_dir.exists():
        print(f"ERROR: Input directory does not exist: {args.input_dir}")
        return 1

    if not args.input_dir.is_dir():
        print(f"ERROR: Input path is not a directory: {args.input_dir}")
        return 1

    images = scan_images(args.input_dir)

    if not images:
        print(f"No supported images found under: {args.input_dir}")
        return 0

    results = load_results(args.output)
    by_path, by_sha1 = make_indexes(results)

    print(f"Model:      {args.model}")
    print(f"Batch size: {args.batch_size}")
    print(f"Input:      {args.input_dir.resolve()}")
    print(f"Output:     {args.output.resolve()}")
    print(f"Found:      {len(images)} images")
    print(f"Existing:   {len(results)} records")
    print()

    pending: list[tuple[Path, str, str]] = []
    skipped = 0

    for image_path in images:
        rel_path = image_path.relative_to(args.input_dir).as_posix()

        try:
            image_hash = sha1_file(image_path)
        except OSError as e:
            print(f"Hash failed: {rel_path}: {e}")
            continue

        existing = None

        if not args.force:
            existing = by_path.get(rel_path)

            # If moved/renamed, try matching by file content hash.
            if existing is None:
                existing = by_sha1.get(image_hash)

        if existing is not None:
            skipped += 1
            continue

        pending.append((image_path, rel_path, image_hash))

    print(f"Pending:    {len(pending)}")
    print(f"Skipped:    {skipped}")
    print()

    if not pending:
        print("Nothing new to classify.")
        print_stats(results)
        return 0

    processed = 0
    failed_batches = 0

    for start in range(0, len(pending), args.batch_size):
        chunk = pending[start:start + args.batch_size]

        paths = [item[0] for item in chunk]
        rel_paths = [item[1] for item in chunk]
        hashes = [item[2] for item in chunk]

        batch_number = start // args.batch_size + 1
        total_batches = (
            len(pending) + args.batch_size - 1
        ) // args.batch_size

        print(
            f"[Batch {batch_number}/{total_batches}] "
            f"{', '.join(rel_paths)}"
        )

        try:
            predictions = classify_batch(
                image_paths=paths,
                relative_paths=rel_paths,
                model=args.model,
                retries=max(0, args.retries),
            )
        except Exception as e:
            failed_batches += 1
            print(f"    FAILED: {e}")
            print("    These images will be retried next time.")
            continue

        image_ids = [f"img_{i+1}" for i in range(len(chunk))]

        # predictions are ordered by image_id, but we also validate all IDs.
        for image_id, image_path, rel_path, image_hash in zip(
            image_ids, paths, rel_paths, hashes
        ):
            prediction = predictions[image_id]

            confidence = float(prediction["confidence"])
            tag = prediction["tag"]

            result = {
                "path": rel_path,
                "sha1": image_hash,
                "tag": tag,
                "confidence": confidence,
                "subject": prediction.get("subject", ""),
                "scene": prediction.get("scene", ""),
                "reason": prediction.get("reason", ""),
                "review_required": (
                    confidence < 0.75 or tag == "Others"
                ),
                "model": args.model,
                "taxonomy_version": "jigsaw-tag-v1.0-21",
            }

            # Replace old record if --force is used or an old record exists.
            results = [
                r for r in results
                if r.get("path") != rel_path and r.get("sha1") != image_hash
            ]

            results.append(result)

            review = " REVIEW" if result["review_required"] else ""

            print(
                f"    {rel_path} -> {tag} "
                f"(confidence={confidence:.2f}){review}"
            )

            processed += 1

        # Save after EVERY successful batch.
        save_results(args.output, results)
        by_path, by_sha1 = make_indexes(results)

        print(f"    Saved {len(results)} records -> {args.output}")

    print("\nDone.")
    print(f"Processed:      {processed}")
    print(f"Skipped:        {skipped}")
    print(f"Failed batches: {failed_batches}")
    print(f"Total records:  {len(results)}")
    print(f"Output:         {args.output.resolve()}")

    print_stats(results)

    if failed_batches:
        print(
            "\nSome batches failed. Re-run the same command to retry them; "
            "successful results will be skipped."
        )

    return 0 if failed_batches == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
