# Daydream Repository Guidelines

## Required Post-Change Workflow

For **every** change that modifies files other than `README.md`:

1. Run the provider test suite:
   ```bash
   python3 tests/run-provider-tests.py
   ```
2. Commit your changes to Git.
3. Run `./install-daydream.command` — do **not** run bare `git push` directly on `main`.
   - `./install-daydream.command` automatically bumps `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, builds and signs the Release app, installs and launches `/Applications/daydream.app`, verifies idle CPU, pushes `main`, and publishes a GitHub Release (`v<version>`).

For **README.md-only** updates, a normal `git commit` + `git push` is sufficient and no GitHub Release is needed.
