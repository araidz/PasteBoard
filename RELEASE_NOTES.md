# PasteBoard release notes

## 2.12 (2026-10-23)

- Copied images are now stored encrypted, like the rest of your history.
  Images saved by earlier versions are encrypted automatically on first launch.
- Large images from apps that only offer TIFF (e.g. some screenshot and design
  tools) are no longer silently skipped; the size limit now applies to the
  compressed image.
- Saved images are written atomically, so a crash mid-save can't leave a
  broken image in history.
- The "copied from" app is taken from the copying app's own declaration when
  it provides one, instead of guessing from the frontmost app.
