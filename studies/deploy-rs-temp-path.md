# deploy-rs `magicRollback` cannot bootstrap a custom `tempPath`

**Finding:** with `magicRollback = true` and a `tempPath` outside `/tmp`, the FIRST deploy to a node
fails unless that directory already exists. deploy-rs creates it — but strictly after the step that
needs it.

Evidence is the source, not the symptom. deploy-rs at `b974715`:

- `src/bin/activate.rs`, `wait()`:
  ```rust
  watcher.watch(&temp_path, RecursiveMode::NonRecursive)?;
  ```
  `notify`'s `watch()` on a path that does not exist returns `ENOENT`, and `wait` propagates it.
  Nothing in `wait` creates `temp_path`.

- `src/bin/activate.rs`, `activation_confirmation()`:
  ```rust
  if let Some(parent) = lock_path.parent() {
      fs::create_dir_all(parent).await...
  ```
  This one DOES create it — and it runs on the activation side, after `wait` has already had its
  turn on the node.

So the ordering is: `wait` (needs the directory) → activation → `activation_confirmation` (creates
the directory). A fresh node never reaches the third step.

**Why it stays hidden.** `src/deploy.rs` defaults `temp_path` to `/tmp`, which exists on every
machine ever built. The bug only appears when an operator moves the path somewhere that survives a
reboot — which is a reasonable thing to want, since the canary file names a system closure and a
tmpfs `/tmp` throws it away.

**Why it reads as a one-off.** Any deploy that gets far enough to activate leaves the directory
behind. So the failure happens once, someone `mkdir`s it by hand or retries after a non-magic
deploy, and it never recurs on that host — while every NEW host has it waiting.

**Hit in production**, 2026-08-04, on a public host: the deploy failed, the operator created
`/var/lib/deploy-rs` by hand, and the next attempt worked. The hand-created directory is also the
reason it looked fixed rather than latent.

**The fix belongs on the receiver.** `nixvps.deployTarget.stagingDir` renders a systemd-tmpfiles
rule (`d <dir> 0700 root root -`), so the node guarantees the directory the same way it guarantees
the substituter trust and the deploy key — declaratively, in the one module that describes what it
means to be deployable. The alternative is every deploy origin remembering to `mkdir` over SSH
first, which states a fact about the receiver in the sender.

Set it to the same path the deploy tool is configured with. They are two statements of one fact and
nothing checks that they agree; if they drift, the symptom is this bug again.
