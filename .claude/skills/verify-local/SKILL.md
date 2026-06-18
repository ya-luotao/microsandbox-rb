---
name: verify-local
description: Run the full local check gate for this gem — cargo fmt --check, cargo clippy -D warnings, standardrb, and the unit specs (optionally integration). Use before pushing, opening a PR, or claiming a change is done. (The bundled /verify skill — run the app and observe behavior — still exists and is separate.)
---

Run the same checks CI gates on, in this order, and report a concise pass/fail summary. Do NOT
stop at the first failure unless a step can't run — collect results from all steps so the user
sees everything at once.

## 1. Rust format check

```sh
cargo fmt --check --manifest-path ext/microsandbox/Cargo.toml
```

If it fails, the fix is `cargo fmt --manifest-path ext/microsandbox/Cargo.toml` (offer to run it).

## 2. Rust lint (clippy, warnings = errors)

```sh
cargo clippy --manifest-path ext/microsandbox/Cargo.toml -- -D warnings
```

## 3. Ruby lint/format (StandardRB)

```sh
bundle exec standardrb
```

If it fails, autocorrect with `bundle exec standardrb --fix` (offer to run it).

## 4. Unit specs (auto-compiles the native ext first)

```sh
bundle exec rake spec
```

This compiles before running, so a stale `.bundle`/`.so` is rebuilt automatically. Requires stable
Rust ≥ 1.91 on PATH.

## 5. Integration specs — only if asked, or `$ARGUMENTS` contains `integration`

These boot real microVMs and need Linux+KVM or macOS Apple Silicon. They auto-skip without the env
var, so skipping them silently is a false "all green". Run only on request:

```sh
MICROSANDBOX_INTEGRATION=1 bundle exec rspec spec/integration
```

## Report

Summarize each step as ✅/❌ with the failing output excerpted. If you changed the public Ruby API,
remind the user to update `sig/microsandbox.rbs` and `CHANGELOG.md` if they haven't.
