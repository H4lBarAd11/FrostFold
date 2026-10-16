# Security

## Reporting a problem

Please don't open a public issue. Report it privately through GitHub instead:
the **Security** tab, then **Report a vulnerability**, or straight to
[this form](https://github.com/H4lBarAd11/FrostFold/security/advisories/new).
Only I can see it until a fix is out, and we can work on the fix together in a
private fork if that helps.

FrostFold is a one-person project, so replies are best-effort, but I aim to
answer within a week.

## Supported versions

Only the [latest release](https://github.com/H4lBarAd11/FrostFold/releases/latest).
A fix ships as a new release rather than as a patch to an old one.

## What matters most

FrostFold holds the Screen Recording permission and sees everything on the
display while the lid is closing. The promise it makes is that captured frames
go from ScreenCaptureKit to the GPU and nowhere else. So the reports I most want
are of anything that breaks that:

- captured frames, or anything derived from them, written to disk, kept after
  the pane has cleared, or readable by another process;
- capture running when the lid is above the engage angle, when the README says
  it is torn down;
- anything that lets something not already running as you reach into FrostFold
  or what it captures.

## Known, and not vulnerabilities

- **The app is not notarised.** The README says so, and says how to open it.
- **`Scripts/signing-identity.sh` has a password in it.** It guards a throwaway
  self-signed key in a keychain of its own, and is there so the script can
  run without a prompt.
- **Something that is already running code as you could record your screen
  itself.** It doesn't need FrostFold for that.
