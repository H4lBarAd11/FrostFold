# Contributing to FrostFold

Thanks for looking. FrostFold is a personal project and it's finished: it does
one thing, and what's left is keeping it doing that on new Macs and new versions
of macOS. So the most useful things, in order, are:

1. **Bug reports**, with your Mac's model and the output of `--selftest`.
   [Open one here](https://github.com/H4lBarAd11/FrostFold/issues/new/choose).
2. **Sensor reports** from Macs the README doesn't list, whether the sensor is
   there or not. Apple doesn't document which models report a continuous lid
   angle, so every report fills in a gap.
3. **Fixes**, as pull requests.

For anything new, such as a setting or a different effect, open an issue first
so we can talk it over before you spend time on it. The app is small on
purpose, and I'd rather say so before you've written the code than after.

## The rule above the rest

FrostFold is a clean-room implementation. It was written from a description of
how the effect should behave, not from anyone else's source, assets or wording.
Contributions have to be the same. Please don't bring in code, shaders, images
or text from another app that does a lid-angle effect, or from a decompiled
one, even as a starting point. If you have read another implementation closely,
say so in the pull request.

## Building

The Xcode Command Line Tools are enough (`xcode-select --install`). The Metal
shaders compile at runtime, so full Xcode isn't needed.

```sh
Scripts/signing-identity.sh    # once, so the Screen Recording grant survives rebuilds
swift test                     # the fold's arithmetic
Scripts/bundle.sh              # native slice only; --universal for both
dist/FrostFold.app/Contents/MacOS/FrostFold --selftest
```

`--preview` opens the preview window, with a scrubber that stands in for the lid.

## Changing the effect

The fold's arithmetic lives in `Sources/FrostFold/FoldGeometry.swift`, kept
apart from AppKit so it can be tested without a lid. Two bugs from there reached
a running build, and neither showed up in a still image: the display flashing
dark as the fold began, and the pane's copy showing over a live display as a
doubled image. Both are now invariants in `Tests/FrostFoldTests`. If a change
makes one of them fail, the change is wrong, not the test. Some of the ramps
look as though they could be simpler. They can't.

To judge a shader change without closing the lid a hundred times, render it:

```sh
Scripts/filmstrip.sh --input shot.png --out .build/filmstrip
```

Put before-and-after stills in the pull request. They show whatever was on your
screen, so use a plain wallpaper or crop them first.

## What won't be merged

- **Network code of any kind**, including analytics, update checks and crash
  reporting. The README promises there is none, and that promise is made to
  everyone who has given the app Screen Recording.
- **Anything that writes captured frames to disk.**
- **Anything that stops honouring** Reduce Motion, Reduce Transparency or
  Increase Contrast.

## Style

Match the code around your change. Comments say why something is there, and
often what went wrong before it. Please keep that up.

The settings panel uses the system text styles rather than fixed point sizes,
`controlSize` rather than forced frames, and the colours in
`Sources/FrostFold/Palette.swift`. It is drawn as glass, which is deliberate:
the app *is* glass.

## Pull requests

- One change per pull request.
- `swift test` and `Scripts/bundle.sh` should both pass. CI runs them on
  macOS 15 and macOS 26, because the Liquid Glass code only builds on the newer
  SDK.
- In the commit message, say in one sentence what changes for someone using the
  app. `git log` has examples.

By contributing, you agree that your work is released under the
[MIT licence](../LICENSE). Everyone taking part is expected to follow the
[code of conduct](CODE_OF_CONDUCT.md).
