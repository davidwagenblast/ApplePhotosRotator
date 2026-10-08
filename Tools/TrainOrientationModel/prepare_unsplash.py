#!/usr/bin/env python3
"""Downloads a random sample of the Unsplash Lite dataset as training photos.

    prepare_unsplash.py LITE_ZIP OUT_DIR COUNT

Writes OUT_DIR/images/<photo_id>.jpg (long edge 768 px) and OUT_DIR/landscapes.txt, the file names of photos whose
description mentions landscape features, used to report landscape accuracy separately.

Unsplash Lite: https://github.com/unsplash/datasets (photos under the Unsplash License).
"""
import concurrent.futures
import csv
import io
import os
import random
import re
import sys
import urllib.request
import zipfile

LANDSCAPE = re.compile(
    r"\b(landscapes?|mountains?|lakes?|beach(es)?|seas?|ocean|coast(line)?|sky|sunsets?|sunrises?|forests?|"
    r"fields?|rivers?|valleys?|hills?|desert|snowy|waterfalls?|cliffs?|islands?|clouds?|cloudy|horizon|meadows?|"
    r"canyons?|countryside|scenery|shore)\b",
    re.IGNORECASE,
)


def main():
    zip_path, out_dir, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
    csv.field_size_limit(sys.maxsize)
    rows = []
    with zipfile.ZipFile(zip_path) as archive:
        names = sorted(n for n in archive.namelist() if os.path.basename(n).startswith("photos."))
        print("photo tables:", names)
        for name in names:
            with archive.open(name) as raw:
                text = io.TextIOWrapper(raw, encoding="utf-8", newline="")
                rows.extend(csv.DictReader(text, delimiter="\t" if ".tsv" in name else ","))
    rows = [r for r in rows if r.get("photo_image_url") and r.get("photo_id")]
    print(f"{len(rows)} photos in the dataset")
    random.Random(1234).shuffle(rows)
    rows = rows[:count]

    images = os.path.join(out_dir, "images")
    os.makedirs(images, exist_ok=True)
    with open(os.path.join(out_dir, "landscapes.txt"), "w") as f:
        for r in rows:
            description = f"{r.get('ai_description') or ''} {r.get('photo_description') or ''}"
            if LANDSCAPE.search(description):
                f.write(r["photo_id"] + ".jpg\n")

    def fetch(r):
        path = os.path.join(images, r["photo_id"] + ".jpg")
        if os.path.exists(path):
            return True
        url = r["photo_image_url"]
        url += ("&" if "?" in url else "?") + "w=768&h=768&fit=max&fm=jpg&q=80"
        for _ in range(3):
            try:
                with urllib.request.urlopen(url, timeout=30) as response:
                    data = response.read()
                with open(path + ".part", "wb") as f:
                    f.write(data)
                os.replace(path + ".part", path)
                return True
            except Exception as error:  # noqa: BLE001 - retry any network failure
                last = error
        print(f"failed {url}: {last}")
        return False

    with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
        ok = sum(pool.map(fetch, rows))
    print(f"downloaded {ok}/{len(rows)} photos")


if __name__ == "__main__":
    main()
