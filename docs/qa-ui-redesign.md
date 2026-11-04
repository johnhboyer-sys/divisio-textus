# QA: window redesign (E + F1), main b131f1e

Installed 2026-11-03. Mock: https://claude.ai/artifact/A9KmGD6vSWoJzMMQk6DYTX

## Differences from the mock (keep or change?)

- [ ] Lock sizes stays in the Stack view's sidebar.
- [ ] Pages are named by scan number ("Page 2"), not "p. 46–47".
- [ ] Remove Trim has no icon.
- [ ] With one page chosen, Grid's sidebar reads "1 Selected".

## Watch for

- [ ] The left rail stays hidden after a double-click in Grid opens a page.
      Seen once; ⌘3 then ⌘1 brought it back. Not reproduced in about eight tries.
      If it happens, note what you did just before.

## Try on a real book

- [ ] Open, crop and export a real scan; check the OCR text in the exported file.
      Only a test book has been checked so far.
