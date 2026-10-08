# Photo Rotator

A macOS app that scans an Apple Photos library (built for 250,000+ photos), finds photos that are sideways or
upside down, and lets you review the proposed fixes as thumbnails before anything changes. You tick a checkbox
on each photo you want fixed and click **Apply**. The app then rotates those photos through Photos' own
non-destructive editing system.

## Requirements

- macOS 14 Sonoma or later
- Xcode 15+ or the Xcode Command Line Tools (Swift 5.9+) to build

## Build and run

```sh
scripts/build_app.sh
open "build/Photo Rotator.app"
```

On first launch, macOS asks for access to your Photos library. Choose **Allow Full Access**.

> Run the app from the `.app` bundle, not with `swift run`. macOS only allows Photos access for a real app bundle
> that declares why it needs access.

To work on the code in Xcode, open `Package.swift`. To run it, still use `scripts/build_app.sh`.

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

The app has no "is this upright?" model built in, so it uses cues that macOS's Vision framework can measure
reliably. Each photo is checked as a small thumbnail.

| Cue | How it decides | Weight |
| --- | --- | --- |
| **Faces** | Vision finds faces at any angle and reports how far each is tilted. A face tilted about 90° means the photo needs a quarter turn; this needs only one Vision pass per photo. Faces tilted 30–45° from a quarter turn are ignored as ambiguous. | 1.0 |
| **People (body pose)** | Checked in all four orientations. The orientation where the neck is above the hips gets the credit (for head-and-shoulders shots, the nose above the neck). | 0.8 |
| **Text** | Checked in all four orientations. Vision can't read sideways text, and it reads upside-down text as gibberish, so the orientation with the most real dictionary words gets the credit. Vision's own confidence score is ignored because it's the same for gibberish and real text. | 0.7 |
| **Core ML model** (optional) | Checked in all four orientations. The model's probability for its "upright" class. | 1.0 |

The scores are combined, and the orientation with the highest score wins. Confidence is how far the winner beats
the runner-up. A photo is only proposed if the winning orientation isn't the current one and the cues agree
clearly. Photos that already look upright are skipped. The cues run in order (faces, body, text, model), and
the app stops as soon as one gives a confident answer, so most photos with faces need just one Vision request.

**What's been checked automatically (CI on a Mac):** a real photo of a person and a page of text are each turned to
all four orientations. Every time, the app proposes the right fix, and applying that fix makes the image upright
again. Body pose alone also gets the direction right on the portrait, but at a low 35% confidence, below the
review screen's default 50% cutoff. These tests don't cover real-world variety: group photos, small faces,
handwriting, and non-Latin text haven't been tested.

**Limitation:** photos with no faces, people, or readable text (landscapes, food, pets, objects) usually can't be
judged by these cues. They're counted as **Not enough to judge** and left alone. Nothing is ever changed without
your approval, so a missed photo costs nothing. But the app won't find every rotated photo unless you add a model.

### Optional: add a Core ML orientation model

Under **What to look for › Core ML orientation model**, choose any Core ML **image classifier** (`.mlmodel`,
`.mlpackage`, or a compiled `.mlmodelc`) that has a class for "upright." Name that class `0`, `0°`, `up`,
`upright`, `none`, or `normal`. For example, a 4-class rotation classifier with labels `0`, `90`, `180`, `270`
works. The app shows the model each of the four orientations and asks how upright it looks, so it doesn't matter
which way the model's other labels count. This is the way to cover photos without people or text.

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
Sources/RotatorCore/         Decision logic (no Apple frameworks; unit tested)
Sources/PhotoRotator/
  App/                       App entry point and state (AppModel)
  Library/PhotoLibrary.swift PhotoKit access: authorization, fetching, thumbnails
  Detection/                 Vision detectors and the four-orientation analyzer
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
