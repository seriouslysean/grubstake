# Copilot Instructions For grubstake

Read `AGENTS.md` for the full rules and `CONTRIBUTING.md` for the workflow. Highlights:

- POSIX `sh` only. CI runs the suite under dash, so a bashism is a failure rather than a style call.
- This repo is public and its consumers are not. Never name a consuming repo anywhere: code, comments, commit messages, issues, or pull requests.
- A fix ships with a test watched failing without it. Run `test/run.sh` before every push.
- Pins are exact versions verified by hash. Never resolve "latest" unprompted, never update a pin automatically, never commit or open a pull request on the user's behalf.
- The commit path stays off the network, and being offline is a reason to stay quiet rather than to fail.
- Replace files by renaming, and leave the old version working until the new one is verified.
- The git hooks grubstake ships are embedded in `grubstake.sh`; `.githooks/` is this repo's own installed copy, and `.claude/` is development policy for this repo.
