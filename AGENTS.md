# AGENTS.md

Rules for working in this repo.

1. Pin every tool to an exact version, and resolve "latest" only when the user explicitly asks to update.
2. Verify downloaded bytes against a recorded hash, because a version tag is not a checksum.
3. Assert that a tool reports the version it was pinned to, since the hash only proves what arrived.
4. Let the machine write pins and let a human review the diff.
5. Never update automatically, and commit and open pull requests on the user's behalf, because the user reviews the diff and merges.
6. Wrap the whole script in `main()` and call it on the last line, so a truncated file is a syntax error rather than a half-executed one.
7. Never rewrite a file that is currently being read, and stage the replacement first instead.
8. Replace files by renaming, because a rename swaps the inode and leaves existing readers intact.
9. Leave the old version working until the new one has been verified.
10. Write POSIX `sh` and avoid bashisms, because these scripts run under `dash` in CI.
11. Keep everything repo-agnostic, so no app names, schemes, bundle identifiers, or paths appear here.
12. Never name a consuming repo anywhere in this repository, including in comments.
13. Keep comments to a single line, and explain why rather than what.
14. Prove that a gate fails on known-bad input before trusting it to pass, and keep that proof as a test.
15. Remember that a gate which never fires looks exactly like one that passes.
16. Make hooks fail loudly or not at all, and never let one skip silently.
17. Keep the network off the commit path entirely.
18. Treat being offline as a reason to stay quiet rather than to fail.
19. Cache binaries outside the repository and commit only text.
20. Use one command for both install and update, so there is nothing to remember.
21. Leave anything that changes for repo-local reasons in the repo that owns it.
22. Ship a fix with a test you have watched fail without it, because a fix verified once by hand is a fix that can be broken silently by the next one.
23. A comment states a constraint the code cannot show, and never what the next line does or why a change is correct.
24. Write terse and factual prose, and never pad it with filler, preamble, or motivational opener.
25. Keep the orchestrating session to routing and judgement, and dispatch implementation and review to the project agents where a harness provides them.
26. Run the adversarial pass over concurrency, portability, and published prose before reporting work done, because the suite only re-proves past failures.
27. State the reason in one sentence when dispatching above an agent's pinned model, since escalation is a decision rather than a default.
28. Keep agent-session links and session trailers out of commit messages, issues, and pull request bodies, because they point outside this repository and the commit-msg hook refuses that shape in a message, where a body has only review.
