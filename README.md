# Photo Rotator

A macOS app that scans an Apple Photos library (built for 250,000+ photos), finds photos that are sideways or
upside down, and lets you review the proposed fixes as thumbnails before anything changes. You tick a checkbox
on each photo you want fixed and click **Apply**. The app then rotates those photos through Photos' own
non-destructive editing system.

## Requirements

- macOS 14 Sonoma or later
- Apple's free Command Line Tools (or Xcode 15+). If they're missing, the installer opens Apple's installer for you;
  run the installer again when that finishes.

## Install (one step)

Paste this into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/davidwagenblast/ApplePhotosRotator/main/install.sh | bash
```

It downloads the code, builds the app, puts **Photo Rotator** in your Applications folder and opens it. The first
build takes a few minutes. Run the same command again any time to update.

If you already have a copy of this repository, run `./install.sh` in it, or double-click
**Install Photo Rotator.command** in Finder. (If Finder says it can't open the file because it was downloaded,
Control-click it, choose **Open**, then **Open** again.)

On first launch, macOS asks for access to your Photos library. Choose **Allow Full Access**. Because the app is
built on your Mac rather than downloaded, macOS may ask again after an update.

### For development

`scripts/build_app.sh` builds `build/Photo Rotator.app` without installing it. To work on the code in Xcode, open
`Package.swift`, but run the app from the `.app` bundle, not with `swift run`: macOS only allows Photos access for
a real app bundle that declares why it needs access.

## How to use it

1. **Scan.** Click **Start Scan**. Progress, speed, and time remaining appear on screen. You can **Stop** at any
   point. Results are saved as the scan goes, and the next scan picks up where the last one stopped. It skips
   photos it has already checked unless they have changed since.
2. **Review.** Switch to **Review**. Each card shows the photo as it looks now and how it will look after the
   proposed rotation.
   - Tick the **Apply** checkbox (or click the card) to select a photo. **Select All** and **Select None** work on
     the photos you can see.
   - Use the **Minimum confidence** slider and the rotation filter to narrow the list.
   - If the direction is wrong, use the `90° ↻` menu on a card to change it.
   - Double-click a card for a larger before/after view.
   - **Hide Selected** marks photos as correct so they stop showing up.
3. **Apply.** Click **Apply to N Selected** and confirm. Photos that could not be rotated are listed with the
   reason and stay in the review list.

**Try a small batch first.** Apply 10–20 photos, including a Live Photo and an iCloud-only photo if you have
them. Check the results in Photos before you do thousands.

## If the proposals look wrong

- **The percentage isn't the chance a proposal is right.** It's how strongly the cues agree. Most photos in a
  library are already upright, so even a small false-alarm rate can produce more wrong proposals than right ones.
  Raise **Minimum confidence** to see fewer, more reliable proposals.
- **Each card says which cues made the call**, for example `faces 90°:0.88 · network 90°:0.71`. Proposals backed by
  faces are the most reliable.
- **Double-click a card** to see "What the scanner analysed". If that image is turned compared with **Now**, the
  scanner looked at the photo the wrong way round. Please report it.
- **Copy Diagnostics** on the review screen copies a text report about the proposals shown: which cue made each
  call and the image sizes involved. It contains no photos or names.
- **Undo All Rotations…** on the scan screen returns every photo the app has rotated to its original, using Photos'
  Revert to Original. That also removes any other edits on those photos.

## How rotations are applied (and why it's safe for your library)

The app never opens or writes the Photos library package on disk. Every change goes through Apple's PhotoKit
editing API (`PHContentEditingOutput` + `PHPhotoLibrary.performChanges`). This is the same path Photos' own
editing extensions use, so Photos updates its own database.

- **Your original is not replaced.** Photos stores the rotated image as an *edited version* next to the
  original. **Image › Revert to Original** in Photos undoes the rotation at any time.
- **Metadata is kept.** The photo stays the same asset, so its capture date, location, title, caption,
  keywords, favorite status, albums, and People stay as they are. The edited image file also copies the
  original's EXIF, TIFF, GPS, and IPTC metadata. Only the orientation tag and pixel dimensions are updated to
  match the rotated pixels.
- **Live Photos stay live.** They are edited with `PHLivePhotoEditingContext`, which rotates the still photo and
  the video together.
- **Existing edits are kept.** If a photo already has edits (a crop, a filter), the rotation is applied on top
  of how the photo looks now. Those earlier edits become part of the new edited version, so they can no longer
  be adjusted one by one. Revert to Original still brings back the untouched original. To leave these photos
  alone, turn on **Skip photos that already have edits** before scanning.
- **Stale proposals are refused.** If a photo changed after it was scanned, the app won't apply the old
  proposal. Rescan to get a fresh one.
- Changes are committed in batches of 8. If a batch fails, each photo in it is retried on its own, so one bad
  photo doesn't block the rest.

### Things to know

- Rotated photos are saved in the type Photos asks for (HEIC for HEIC originals, otherwise JPEG) at high
  quality. The original file is never re-encoded. The edited version is a new encode, as with any edit in Photos.
- HDR "gain map" data from iPhone HEIC photos isn't carried into the edited version, so the edited version shows
  in standard range. The original keeps it.
- Photos that live only in iCloud are downloaded at full size when you apply. This can take a while.

## How detection works

Each photo is checked as a small thumbnail, using macOS's Vision framework plus a small model trained for this app.

| Cue | How it decides | Weight |
| --- | --- | --- |
| **Faces** | Vision finds faces at any angle and reports how far each is tilted. A face tilted about 90° means the photo needs a quarter turn; this needs only one Vision pass per photo. Faces tilted 30–45° from a quarter turn are ignored as ambiguous. | 1.0 |
| **People (body pose)** | Checked in all four orientations. The orientation where the neck is above the hips gets the credit (for head-and-shoulders shots, the nose above the neck). | 0.8 |
| **Scenes — landscapes, buildings, objects, anything** | A built-in image-recognition network (MobileNetV3), fine-tuned to tell which way a photo is turned. It's checked in all four orientations and the four estimates are averaged. If a build doesn't include the network, a lighter built-in scene model is used instead. | 1.0 |
| **Text** | Checked in all four orientations. Vision can't read sideways text, and it reads upside-down text as gibberish, so the orientation with the most real dictionary words gets the credit. Vision's own confidence score is ignored because it's the same for gibberish and real text. | 0.7 |
| **Core ML model** (optional) | Checked in all four orientations. The model's probability for its "upright" class. | 1.0 |

The scores are combined, and the orientation with the highest score wins. Confidence is how far the winner beats
the runner-up. A photo is only proposed if the winning orientation isn't the current one and the cues agree
clearly. Photos that already look upright are skipped. The cues run in order (faces; then body pose and scenes
together; then text; then your model), and the app stops as soon as it has a confident answer, so most photos with
faces need just one Vision request.

### How well it works

**Faces and text** (CI on a Mac): a real photo of a person and a page of text are each turned to all four
orientations. Every time, the app proposes the right fix, and applying that fix makes the image upright again.

**Scenes** were measured on 1,777 held-out Unsplash photos that the network never saw in training, each tested in
all four orientations. The network ran as the app runs it (Core ML through Vision), with faces, body pose and text
turned off so the numbers show the network alone.

The network was trained with all four turns equally likely, but in a real library almost every photo is upright,
sideways photos are occasional and upside-down ones rare. Used as trained, it flagged 3% of upright photos at 50%
confidence, and in a real library those false alarms (mostly "upside down") outnumbered the real finds. So the app
weighs it by realistic odds (90% upright, 4.5% each sideways direction, 1% upside down):

| Review minimum confidence | Sideways photos found | Upside-down photos found | Wrong direction | Upright photos wrongly flagged |
| --- | --- | --- | --- | --- |
| 30% | 60% (landscapes 79%) | 0.3% | 0.6% | 0.2% |
| 50% (default) | 51% (landscapes 70%) | 0% | 0.2% | 0% of 1,777 |
| 60% | 28% (landscapes 39%) | 0% | 0.1% | 0% |

So at the default setting the network finds about half of sideways photos with no measured false alarms, but it
won't propose upside-down turns on its own. Upside-down photos with faces, people or text are still found by
those cues. Lowering **Minimum confidence** to 30% finds more sideways photos, with a few false alarms. Your
photos may score differently from Unsplash test photos: report what you see with **Copy Diagnostics**. Full
tables, including the other odds that were tried: `Models/OrientationNet-report-coreml.txt`.

### How the network was trained

`.github/workflows/train-orientation-net.yml` fine-tunes an ImageNet-pretrained MobileNetV3-Large (from
torchvision) on the 25,000 photos of the [Unsplash Lite dataset](https://github.com/unsplash/datasets) (Unsplash
License), on a GitHub Linux runner. No one labels anything: each photo is assumed upright and shown turned a random
number of quarter turns, with random crops, mirroring and colour changes. Photos are split by name into training
(75%), validation (10%, used to keep the best epoch) and test (15%). The model is converted to Core ML (8 MB,
16-bit) and committed to `Models/OrientationNet.mlpackage`; then
`.github/workflows/evaluate-orientation-net.yml` runs it through Vision on a Mac exactly as the app does and
commits the report above. The build script compiles the model into the app.

Training ran 14 epochs (about 4½ hours on CPU) and reached 85.3% single-pass validation accuracy. The four-pass
average the app uses does better than any single pass. A larger network, more training time, or more photos would
likely improve it further.

The lighter scene model (`Tools/TrainOrientationModel`, a small classifier on Vision's feature print plus a
colour-and-edge layout map) is kept as the fallback for builds without the network.

### Optional: add a Core ML orientation model

Under **What to look for › Core ML orientation model**, choose any Core ML **image classifier** (`.mlmodel`,
`.mlpackage`, or a compiled `.mlmodelc`) that has a class for "upright." Name that class `0`, `0°`, `up`,
`upright`, `none`, or `normal`. For example, a 4-class rotation classifier with labels `0`, `90`, `180`, `270`
works. The app shows the model each of the four orientations and asks how upright it looks, so it doesn't matter
which way the model's other labels count. Use this if you have a stronger orientation model than the built-in one.

## Performance at 250,000 photos

- Photos are fetched lazily from a `PHFetchResult`. Only a few are in memory at a time (set by **Photos in
  parallel**), and each one is a small thumbnail (512–1024 px), so memory use stays flat during a long scan.
- By default, analysis uses the thumbnails Photos already keeps on your Mac. Photos that are only in iCloud are
  reported as **Not available locally** unless you allow downloads. Downloading a quarter of a million photos
  would be slow and use a lot of space.
- Results go into a SQLite file at `~/Library/Application Support/PhotoRotator/scan.sqlite`, saved in batches of 250.
  Stopping, quitting, or a crash loses at most the last few seconds of work.
- Speed depends a lot on your Mac and on how many photos contain faces or text. The scan screen shows the real
  rate and time remaining once it's running. Expect a full first scan of a large library to take hours, so
  leaving it running overnight is reasonable. Later scans only check new or changed photos.

## Project layout

```
Sources/RotatorCore/         Decision logic, scene classifier and trainer, layout features (no Apple frameworks)
Sources/RotatorVision/       Vision feature extraction shared by the app and the trainer
Tools/TrainOrientationNet/   Fine-tunes the orientation network (run by .github/workflows/train-orientation-net.yml)
Tools/EvaluateOrientationNet/ Scores the Core ML network through Vision on held-out photos
Tools/TrainOrientationModel/ Trains the fallback scene model (run by .github/workflows/train-scene-model.yml)
Models/                      The trained orientation network and its evaluation reports
Sources/PhotoRotator/
  App/                       App entry point and state (AppModel)
  Library/PhotoLibrary.swift PhotoKit access: authorization, fetching, thumbnails
  Detection/                 Vision detectors, the four-orientation analyzer, built-in scene model weights
  Scan/                      Parallel, resumable library scan
  Store/ResultStore.swift    SQLite persistence of scan results
  Apply/RotationApplier.swift Non-destructive PhotoKit edits
  UI/                        SwiftUI scan and review screens
Support/                     Info.plist and entitlements for the app bundle
scripts/build_app.sh         Builds and signs the .app
```

Run the tests with `swift test`. The face tests need an upright photo of a person; point `FACE_IMAGE` at one:

```sh
FACE_IMAGE=~/Pictures/someone.jpg swift test
```

The GitHub Actions workflow (`.github/workflows/build.yml`) runs the tests and builds the app on a macOS runner
on every push.
