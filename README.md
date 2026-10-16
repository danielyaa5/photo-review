<p align="center"><img src="assets/icon.svg" width="120" alt=""></p>
<h1 align="center">Photo Review</h1>
<p align="center">See what is filling your iCloud Photos storage, then compress the videos or delete what you don't need.</p>
<p align="center"><a href="https://danielyaa5.github.io/photo-review/"><b>Website and download</b></a></p>

![Previewing a video, selecting three, compressing them and seeing the space saved](docs/demo.gif)

<sub>The demo uses made-up names and sizes, with free placeholder photos standing in for a real library. In
real use macOS asks you to confirm before anything is deleted; that dialog isn't shown here.</sub>

Photos on the Mac can't sort by file size, so a handful of huge videos can quietly use most of an iCloud plan.
Photo Review lists everything in your library from largest to smallest, lets you preview each item, and gives
you two ways to get space back: delete it, or replace a video with a much smaller copy.

It runs entirely on your Mac. It is a small app that serves a page to your own browser at `127.0.0.1`; nothing
is uploaded anywhere.

## What it does

- **Largest first.** Every photo and video with its real stored size, including edited versions and Live
  Photo video. Filter by type or year.
- **Preview before deciding.** Thumbnails for everything, and in-page playback for videos, including ones
  that are only in iCloud.
- **Three separate picks.** Each video has Compress & delete, Delete and Compress buttons, so you can line up
  some videos to compress and other things to delete, then start it all with one button. Compress & delete
  compresses a video, then deletes the original once the whole queue has finished. A video in the queue shows
  its progress on its tile, and one that has already been compressed says so and offers only Delete original.
  The smaller copies themselves carry a "Compressed from 25.60 GB" label, so they aren't mistaken for videos
  still to do.
- **Compress videos.** Pick a resolution cap (4K, 1080p, 720p), a frame-rate cap, HEVC or H.264, and a quality
  level. A size estimate updates as you choose. The smaller copy is added to Photos with the original's date,
  location, favorite flag and albums.
- **HDR stays HDR.** iPhone HDR video is re-encoded as 10-bit HEVC with HDR intact. ProRes and other 10-bit
  footage keeps its 10 bits too: it is saved as 10-bit HEVC even if you chose H.264, which would flatten it
  to 8 bits. Slo-mo keeps its timing and sound.
- **Delete with a safety net.** Nothing is removed until you approve the standard macOS confirmation, and
  deleted items go to Recently Deleted for 30 days.
- **Savings page.** A running total of what you have freed, split into what compressing saved and what
  deleting saved, plus what is still waiting on you. One history table lists every compression and deletion,
  and sorts by date, by size or by space saved.
- **Quick to reopen.** Measuring a large library takes a minute or more, so the result is kept for a day.
  The page says when it was measured, and "Update now" measures again.

| The library, with a queue running | Choosing how far to compress | Savings and history |
|---|---|---|
| ![The library view, largest first](docs/screenshot-library.png) | ![The compress dialog with a per-video size estimate](docs/screenshot-shrink.png) | ![The savings page](docs/screenshot-savings.png) |

The library and compress screenshots use made-up data; the Savings one is the author's own history. The pictures
in those two screenshots and in the demo are free placeholder photos from [Lorem Picsum](https://picsum.photos),
which draws on [Unsplash](https://unsplash.com/license).

## How compressing works

Photos has no way to swap a video's file in place, so compressing a video takes three steps:

1. The original is downloaded from iCloud at full quality (skipped if it is already on your Mac).
2. It is re-encoded on your Mac with Apple's hardware encoder.
3. The smaller copy is added to Photos as a new item, named like `IMG_1234 (compressed).mov` (copies made
   before version 0.5.16 end in `(shrunk)` instead).

The original is left alone. Its tile then says it has been compressed and offers only Delete original, so once
you have checked the new copy you delete the original yourself. Or pick a video with Compress & delete instead
of Compress, or tick "Delete each original" when starting a batch: once the whole queue has finished, the app
asks Photos to delete the originals of those videos that compressed successfully, and macOS asks you to
confirm once. To compress a video again with different settings, delete its smaller copy first. If a
re-encode would not save a meaningful amount, the video is skipped instead.

As an example, a 43-second 4K HDR iPhone clip went from 482 MB to 27 MB at 1080p, 30 fps, medium quality.
Savings are largest on ProRes and high-bitrate action-camera footage.

## Install

1. [Download PhotoReview.zip](https://github.com/danielyaa5/photo-review/releases/latest/download/PhotoReview.zip)
   (the latest release).
2. Unzip it and move **Photo Review** to your Applications folder.
3. Open it.

The app is signed and notarized by Apple, so it opens like any other downloaded app. It runs on Apple silicon
and Intel Macs with macOS 13 or later, though it has only been tested on macOS 27.

On first launch macOS asks whether Photo Review may access your Photos library; choose **Allow Full Access**,
since it needs to read sizes, add compressed copies and delete what you select. Your browser then opens at
`http://127.0.0.1:8377`. The first measurement of a large library takes a minute or more, with the biggest
videos shown first; after that the app opens straight away for the rest of the day.

Keep the small Photo Review window open while you work. Closing it quits the app.
Before a large batch, read [Managing the size of your Photos library](#managing-the-size-of-your-photos-library)
and leave room for the originals to download.

### Building it yourself

You need Apple's command line tools (`xcode-select --install`).

```bash
git clone https://github.com/danielyaa5/photo-review.git
cd photo-review
./build.sh
open "Photo Review.app"
```

A local build is signed for your Mac only and uses a different app identity from the release, so macOS asks
for Photos access separately for each.

## Managing the size of your Photos library

**Your Mac's Photos library can grow while you compress videos.** Photos downloads full-quality originals
from iCloud, and the smaller copies are added alongside them. Photo Review removes its own temporary
conversion files, but Photos controls how long downloaded originals stay on disk. The Savings page tracks
changes to the items in your library; it does not measure free disk space on your Mac.

In **Photos → Settings → iCloud**, select **Optimize Mac Storage** if you use iCloud Photos. Photos can keep
smaller local versions when space is limited, but this does not immediately clear recent downloads. Work in
smaller batches if disk space is tight: downloads from a long queue can accumulate, and **Compress & delete**
or **Delete each original** asks for deletion only after the whole queue finishes.

To reclaim space after a batch:

1. Play each smaller copy in Photos and check its picture, sound and full length. Confirm it has uploaded
   to iCloud, and keep a separate backup of the original if you may want its full quality later.
2. Delete the replaced originals using **Delete original** in Photo Review, or approve the batch's
   deletion request if you used **Compress & delete** or **Delete each original**. They move to Recently Deleted.
3. To remove those originals sooner than the usual 30 days, open **Recently Deleted** in Photos on your
   Mac, or sign in to [iCloud Photos](https://www.icloud.com/photos) and open **Recently Deleted** there.
   Select only the originals you have checked and replaced, then choose **Delete** and confirm. Avoid
   **Delete All** unless you intend to permanently remove every item in that album.
4. Give Photos time to sync and clean up. Removing replaced originals from Recently Deleted can
   substantially reduce the local library size, but the space may not return immediately.

**Permanent deletion removes the originals from iCloud and every device using iCloud Photos, and ends
the 30-day recovery option.** The smaller copies remain as separate items. Photo Review does not empty
Recently Deleted for you. If you keep an original in the main library, Photos still decides when to clear
its local download.

See Apple's guidance on [Optimize Mac Storage](https://support.apple.com/en-us/guide/photos/phta9b4673b4/mac)
and [deleting and recovering items on iCloud.com](https://support.apple.com/guide/icloud/mm08b49040b5/icloud).

## Things to know before you rely on it

- **It is new.** It has been tested on two Macs so far, and used for real on one large library.
  Start with a video you don't care about, and keep a backup of anything irreplaceable.
- **Downloads are the slow part.** Photos fetches one original at a time, so a 25 GB video can take over an
  hour before encoding starts. Dropped connections are retried, and Photos has resumed where it left off.
- **Originals stay on disk for a while.** A downloaded original remains on your Mac until Photos clears it,
  so a long queue needs free disk space. The app refuses to start a download it has no room for. See
  [Managing the size of your Photos library](#managing-the-size-of-your-photos-library) for cleanup steps.
- **Some things don't carry over to a compressed copy:** edits are baked in rather than kept as edits, and
  captions, keywords, people tags and shared-album membership are lost.
- **Dolby Vision.** The copy keeps the HDR picture. Whether the iPhone's extra Dolby Vision metadata survives
  has not been checked; if it doesn't, the video still plays as HDR.
- **Deletion has a recovery period.** Deleted items remain in Recently Deleted for 30 days unless you
  permanently delete them sooner. Photos may need time to sync and reclaim local storage.
- **Changes made elsewhere.** Items deleted in the Photos app or on another device drop out of the list as
  soon as it is shown again. New photos and videos don't appear until the library is measured again: once a
  day, or when you click "Update now".

## How it is built

One Swift file and two HTML pages, with no dependencies beyond macOS itself.

- `main.swift`: the app. It reads the library through PhotoKit (Apple's supported interface, not the library
  database), serves the pages from a loopback-only HTTP server, re-encodes with AVFoundation and VideoToolbox,
  and keeps its history and the day's measurement in `~/Library/Application Support/Photo Review/`.
- `index.html` and `stats.html`: the library view and the savings page.
- `build.sh`: compiles and signs the app locally.
- `release/`: builds the signed, notarized download (needs a paid Apple Developer team signed in to Xcode).

State-changing requests need a token that only the page served by the app has, and requests arriving under
any other hostname are rejected, so other websites can't drive it.

For development, `--port N` runs a second copy on another port, and `--history FILE` and `--cache FILE` point
it at different data files. A shrink request with `"dryRun": true` encodes to a temporary file and adds nothing to Photos.

## Similar projects

- [PhotoSlim](https://github.com/EvanXuu/photoslim) and [PixelPare](https://github.com/akshaymaloo/pixelpare)
  are native apps that also compress Photos videos to HEVC. Both skip HDR video by design; PixelPare also finds
  duplicate photos and old screenshots.
- [osxphotos](https://github.com/RhetTbull/osxphotos) is the standard command-line tool for querying and
  exporting a Photos library.
- [Finding big photos](https://alexwlchan.net/2023/finding-big-photos/) describes the size-listing approach
  this app uses.

## License

MIT. See [LICENSE](LICENSE).
