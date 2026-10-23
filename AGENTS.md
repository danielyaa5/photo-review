# Photo Review project instructions

Native macOS app with a web interface for reviewing/compressing large media from Apple Photos, Google Drive folders, and local folders. Read `README.md`, `build.sh`, `main.swift`, and `index.html` before editing.

- Keep new feature work uncommitted until the user has tested it personally.
- Keep source ordering Apple Photos → Google Drive → Local Folder, with a small fixed sidebar; dynamic folders belong in the source page.
- Build instructions are in `build.sh`; inspect them before execution because builds/signing/install steps may affect the local app. There is no general test suite identified at the repo root.
- Verify the real changed flow using disposable media. Do not delete originals, alter a personal library, or disturb a running compression queue merely to test a change.
- Distinguish local temporary files, cloud downloads, replacement imports, and original deletion. Verify playable output and metadata as applicable; a completed build is not proof of library behavior.
- Public screenshots/demos use fictional names and placeholder media; library exports, personal filenames, and private launch/outreach notes stay private.

## Working rules

- Preserve unrelated changes and use the repository's existing conventions.
- Test changes through the real user flow before saying they work. State what could not be tested and why. A passing build or a saved setting is not end-to-end verification.
- Run browser tests headlessly when no visible interaction is needed. Close only the windows/tabs you opened and stop only the temporary servers you started.
- Never send email on the user's behalf without showing the complete draft and receiving approval of that exact version. Changes to the draft require renewed approval.
- Do not add AI attribution, AI co-author trailers, or session links to commits, PRs, issues, releases, or comments. Use the repository owner's configured Git identity; never invent an identity.
- Before starting a new product or tool, research existing solutions, compare their fit/cost/limitations, and wait for the user's choice. Routine fixes, additions to existing projects, and throwaway scripts do not require that step.
- Give progress updates during long work. Do not stop or restart a slow job the user is waiting on without asking.
- Keep credentials, personal identifiers, account details, private hostnames, and private notebooks out of repository instructions and public artifacts. Use fictional test data and repo-relative paths.
- Keep durable public project knowledge in this file or focused project docs. Private notes belong in the agent's configured private context store, if available; a cloud task must work from this repo without access to private files.
