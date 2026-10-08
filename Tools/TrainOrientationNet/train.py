#!/usr/bin/env python3
"""Fine-tunes an ImageNet-pretrained MobileNetV3 to tell which way a photo is turned, and exports it to Core ML.

    train.py --images DIR --work DIR --out DIR [--landscapes FILE] [--epochs 14] [--time-budget-minutes 240]

Every photo in DIR is assumed upright. During training each photo is shown turned a random number of quarter turns
counter-clockwise; the label is how many quarter turns clockwise it then needs (0-3). Photos are split by a hash of
their file name — the same FNV-1a split the Swift tools use — into training (75%), validation (10%, used to keep the
best epoch) and test (15%, never used for training).

Outputs in --out:
  OrientationNet.mlpackage   Core ML model: 224x224 RGB image in, probabilities for labels "0", "90", "180", "270"
  report-pytorch.txt         held-out results of the PyTorch model, in the app's decision terms
  test-probabilities.npy     the PyTorch model's test-set probabilities [photo, needed quarter turns, class]

The converted model is evaluated separately on a Mac, through Vision (.github/workflows/evaluate-orientation-net.yml).
"""
import argparse
import math
import os
import random
import time

import numpy as np
import torch
import torch.nn as nn
from PIL import Image, ImageOps
from torch.utils.data import DataLoader, Dataset
from torchvision import transforms
from torchvision.models import MobileNet_V3_Large_Weights, mobilenet_v3_large

INPUT = 224
LABELS = ["0", "90", "180", "270"]
MEAN = [0.485, 0.456, 0.406]
STD = [0.229, 0.224, 0.225]
THRESHOLDS = [0.3, 0.5, 0.6, 0.7, 0.8]


def bucket(name):
    """FNV-1a, matching the Swift tools, so every tool agrees on which photos are test photos."""
    h = 0xCBF29CE484222325
    for byte in name.encode("utf-8"):
        h = ((h ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h % 100


def log(message):
    print(message, flush=True)


def prepare(images, resized):
    """Downsizes every photo once (long edge 320 px), applying any EXIF orientation like the Swift tools do."""
    os.makedirs(resized, exist_ok=True)
    names = sorted(n for n in os.listdir(images) if n.lower().endswith(".jpg"))
    done = 0
    for name in names:
        target = os.path.join(resized, name)
        if os.path.exists(target):
            continue
        try:
            with Image.open(os.path.join(images, name)) as image:
                image = ImageOps.exif_transpose(image).convert("RGB")
                image.thumbnail((320, 320), Image.LANCZOS)
                image.save(target, quality=92)
        except Exception as error:  # noqa: BLE001 - skip unreadable files
            log(f"skipping {name}: {error}")
        done += 1
        if done % 2000 == 0:
            log(f"  resized {done}")
    return sorted(n for n in os.listdir(resized) if n.lower().endswith(".jpg"))


def turned(image, quarter_turns):
    """The photo turned counter-clockwise, so it then needs `quarter_turns` clockwise to be upright."""
    return [image, image.transpose(Image.Transpose.ROTATE_90), image.transpose(Image.Transpose.ROTATE_180),
            image.transpose(Image.Transpose.ROTATE_270)][quarter_turns]


class TrainingSet(Dataset):
    def __init__(self, paths):
        self.paths = paths
        self.flip = transforms.RandomHorizontalFlip()  # mirroring never changes which way is up
        self.colour = transforms.ColorJitter(0.25, 0.25, 0.25, 0.03)

    def __len__(self):
        return len(self.paths)

    def __getitem__(self, index):
        with Image.open(self.paths[index]) as image:
            image = image.convert("RGB")
        # A random crop of 60-100% of the area, keeping roughly the photo's own aspect ratio.
        w, h = image.size
        top, left, ch, cw = transforms.RandomResizedCrop.get_params(image, (0.6, 1.0), (0.75 * w / h, 1.333 * w / h))
        image = self.colour(self.flip(image.crop((left, top, left + cw, top + ch))))
        label = random.randrange(4)
        # Turn first, then squash to a square, exactly as Vision does in the app (orientation, then scaleFill).
        image = turned(image, label).resize((INPUT, INPUT), Image.BILINEAR)
        return transforms.functional.to_tensor(image), label


class AllTurns(Dataset):
    """Every photo in all four turns, for evaluation: item 4*i + k is photo i needing k quarter turns."""

    def __init__(self, paths):
        self.paths = paths

    def __len__(self):
        return len(self.paths) * 4

    def __getitem__(self, index):
        with Image.open(self.paths[index // 4]) as image:
            image = image.convert("RGB")
        image = turned(image, index % 4).resize((INPUT, INPUT), Image.BILINEAR)
        return transforms.functional.to_tensor(image), index % 4


class OrientationNet(nn.Module):
    """MobileNetV3-Large with a 4-way head. Takes RGB in 0...1; ImageNet normalisation is part of the model."""

    def __init__(self, pretrained=True):
        super().__init__()
        self.backbone = mobilenet_v3_large(weights=MobileNet_V3_Large_Weights.IMAGENET1K_V2 if pretrained else None)
        self.backbone.classifier[3] = nn.Linear(self.backbone.classifier[3].in_features, 4)
        self.register_buffer("mean", torch.tensor(MEAN).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(STD).view(1, 3, 1, 1))

    def forward(self, x):
        return self.backbone((x - self.mean) / self.std)


@torch.no_grad()
def probabilities(model, paths, workers):
    """Array [photo, needed quarter turns, class] of softmax probabilities."""
    model.eval()
    loader = DataLoader(AllTurns(paths), batch_size=128, num_workers=workers)
    out = []
    for x, _ in loader:
        out.append(torch.softmax(model(x), dim=1).numpy())
    return np.concatenate(out).reshape(len(paths), 4, 4)


def decide(scores, weight=1.0, minimum_strength=0.3, minimum_confidence=0.2):
    """Python port of RotatorCore.OrientationDecider for one detector's scores."""
    combined = [weight * s for s in scores]
    ranked = sorted(range(4), key=lambda r: (-combined[r], r))
    best, second = combined[ranked[0]], combined[ranked[1]]
    if best < minimum_strength:
        return "inconclusive", 0, 0.0
    confidence = min(max((best - second) / max(best, 1.0), 0.0), 1.0)
    if ranked[0] == 0:
        return "upright", 0, confidence
    return ("needsRotation" if confidence >= minimum_confidence else "inconclusive"), ranked[0], confidence


def report(title, probs):
    """The app's four-pass averaging and decision, tallied like the Swift trainer's report."""
    upright = rotated = 0
    false_proposals = [0] * len(THRESHOLDS)
    correct = [0] * len(THRESHOLDS)
    wrong = [0] * len(THRESHOLDS)
    for p in probs:
        for truth in range(4):
            scores = [0.0] * 4
            for pass_turns in range(4):
                frame = p[(truth - pass_turns) % 4]
                for c in range(4):
                    scores[(pass_turns + c) % 4] += frame[c] / 4
            status, rotation, confidence = decide(scores)
            if truth == 0:
                upright += 1
            else:
                rotated += 1
            for i, threshold in enumerate(THRESHOLDS):
                proposed = status == "needsRotation" and confidence >= threshold
                if truth == 0 and proposed:
                    false_proposals[i] += 1
                if truth != 0 and proposed:
                    if rotation == truth:
                        correct[i] += 1
                    else:
                        wrong[i] += 1

    def pct(n, total):
        return "—" if total == 0 else f"{100 * n / total:.1f}%"

    lines = [f"{title}: {upright} upright and {rotated} rotated test cases",
             "  min confidence | rotated: found correctly | rotated: wrong direction | upright: wrongly proposed"]
    for i, threshold in enumerate(THRESHOLDS):
        lines.append(f"  {threshold * 100:13.0f}% | {pct(correct[i], rotated):>24} | {pct(wrong[i], rotated):>24} | "
                     f"{pct(false_proposals[i], upright):>25}")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--images", required=True)
    parser.add_argument("--work", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--landscapes")
    parser.add_argument("--epochs", type=int, default=14)
    parser.add_argument("--batch", type=int, default=64)
    parser.add_argument("--lr", type=float, default=6e-4)
    parser.add_argument("--time-budget-minutes", type=float, default=240)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--no-pretrained", action="store_true", help="random initial weights (for quick smoke tests)")
    args = parser.parse_args()

    random.seed(7)
    torch.manual_seed(7)
    threads = os.cpu_count() or 4
    torch.set_num_threads(threads)
    workers = max(1, min(4, threads - 1))

    resized = os.path.join(args.work, "resized")
    names = prepare(args.images, resized)
    log(f"{len(names)} photos ready")
    if args.prepare_only:
        return

    train = [n for n in names if bucket(n) >= 25]
    validation = [n for n in names if 15 <= bucket(n) < 25]
    test = [n for n in names if bucket(n) < 15]
    landscapes = set()
    if args.landscapes and os.path.exists(args.landscapes):
        landscapes = set(open(args.landscapes).read().split())
    log(f"train {len(train)}, validation {len(validation)}, test {len(test)}")
    path = lambda n: os.path.join(resized, n)  # noqa: E731

    model = OrientationNet(pretrained=not args.no_pretrained)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=0.05)
    criterion = nn.CrossEntropyLoss(label_smoothing=0.05)
    loader = DataLoader(TrainingSet([path(n) for n in train]), batch_size=args.batch, shuffle=True,
                        num_workers=workers, drop_last=True, persistent_workers=True)
    steps_per_epoch = len(loader)
    epochs = args.epochs
    budget = args.time_budget_minutes * 60
    started = time.time()
    best_accuracy, best_state = -1.0, None
    step = 0

    epoch = 0
    while epoch < epochs:
        epoch += 1
        model.train()
        epoch_started = time.time()
        total_loss = correct = seen = 0
        for x, y in loader:
            # One warm-up epoch, then cosine decay over however many epochs fit in the time budget.
            total_steps = epochs * steps_per_epoch
            progress = step / total_steps
            lr = args.lr * min(1.0, (step + 1) / steps_per_epoch) * 0.5 * (1 + math.cos(math.pi * min(progress, 1.0)))
            for group in optimizer.param_groups:
                group["lr"] = lr
            optimizer.zero_grad()
            logits = model(x)
            loss = criterion(logits, y)
            loss.backward()
            optimizer.step()
            step += 1
            total_loss += loss.item() * len(y)
            correct += (logits.argmax(1) == y).sum().item()
            seen += len(y)

        p = probabilities(model, [path(n) for n in validation], workers)
        accuracy = float((p.argmax(2) == np.arange(4)).mean())
        elapsed = time.time() - epoch_started
        log(f"epoch {epoch}/{epochs}: loss {total_loss / seen:.4f}, train accuracy {100 * correct / seen:.2f}%, "
            f"validation accuracy {100 * accuracy:.2f}% ({elapsed / 60:.1f} min)")
        if accuracy > best_accuracy:
            best_accuracy = accuracy
            best_state = {k: v.clone() for k, v in model.state_dict().items()}
        if epoch == 1:
            fit = int((budget - (time.time() - started)) // elapsed) + 1
            if fit < epochs:
                epochs = max(2, fit)
                log(f"time budget allows {epochs} epochs")

    model.load_state_dict(best_state)
    model.eval()

    test_probs = probabilities(model, [path(n) for n in test], workers)
    single = float((test_probs.argmax(2) == np.arange(4)).mean())
    landscape_probs = test_probs[[i for i, n in enumerate(test) if n in landscapes]]
    summary = "\n".join([
        f"Orientation network: MobileNetV3-Large (ImageNet) fine-tuned for 4-way rotation, {INPUT}x{INPUT} input.",
        f"Trained on {len(train)} photos for {epoch} epochs; best validation accuracy {100 * best_accuracy:.1f}% "
        f"on {len(validation)}; tested on {len(test)} held-out photos.",
        f"Single-pass test accuracy: {100 * single:.1f}%.",
        "",
        report("All test photos", test_probs),
        "",
        report(f"Landscape test photos ({len(landscape_probs)} photos)", landscape_probs),
    ])
    log("\n" + summary)

    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "report-pytorch.txt"), "w") as f:
        f.write(summary + "\n")
    np.save(os.path.join(args.out, "test-probabilities.npy"), test_probs)

    export(model, os.path.join(args.out, "OrientationNet.mlpackage"), summary)


def export(model, destination, summary):
    import coremltools as ct

    wrapped = nn.Sequential(model, nn.Softmax(dim=1)).eval()
    traced = torch.jit.trace(wrapped, torch.rand(1, 3, INPUT, INPUT))
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, INPUT, INPUT), scale=1 / 255.0,
                             color_layout=ct.colorlayout.RGB)],
        classifier_config=ct.ClassifierConfig(LABELS),
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
    )
    mlmodel.short_description = ("Which way a photo is turned. Labels: quarter turns clockwise the photo needs "
                                 "(0, 90, 180, 270 degrees).")
    mlmodel.user_defined_metadata["summary"] = summary
    mlmodel.save(destination)
    log(f"saved {destination}")


if __name__ == "__main__":
    main()
