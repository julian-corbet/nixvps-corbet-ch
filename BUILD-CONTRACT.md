# The Build Contract: Producer ↔ Node

`nixvps` is a **receiver** — the modules handle tiny-node system shape and
autonomous update delivery. Builders and CI pipelines are **deliberately out of
scope**: every team's build infrastructure is different, and nixvps does not
prescribe yours.

Instead, nixvps expects you to bring your own build system — whatever that is
— and satisfy a simple contract so any producer can feed any nixvps node.

## What the contract is

A nixvps node is configured to trust a signed binary cache and to read a
pointer. Your builder's only job: produce a signed closure the node can
substitute and activate.

### Part 1: Build on a real machine

Build the target system closure **outside** the tiny node, on a machine with
resources (a laptop, a beefy VM, or a real CI runner). Never build on the
1-GB node itself — it will OOM or take hours.

```bash
nix build .#nixosConfigurations.myhost.config.system.build.toplevel
```

This produces a result symlink pointing to `/nix/store/...-nixos-system-myhost-...`.

### Part 2: Sign and push to a binary cache

Your binary cache must sign the closure with a key the node trusts. Push the
signed closure to a cache reachable by your node — same network, same cloud
provider, or public internet, depending on your node's network model.

```bash
# Using cachix (typical GitHub Actions example):
cachix push mycache $(nix-build --no-link .#nixosConfigurations.myhost.config.system.build.toplevel)
```

The cache signs it with your `mycache-1` key. Configure the node to trust that
key via `nixvps.deployTarget.trustedPublicKeys` or `nixvps.pullUpdate.cache`
(whichever model you use).

### Part 3: Publish a pointer the node can read

Depending on how the node pulls updates:

- **For `pull-update` nodes** (autonomous, timer-based): Publish a DNS TXT
  record at `_deploy.<hostname>.<domain>` naming the store path. The node will
  read it on its polling interval.
  
  ```bash
  # Your build pipeline publishes:
  dig TXT _deploy.myhost.example.com
  # Returns: "v=1 /nix/store/...-nixos-system-myhost-..."
  ```
  
  Use any DNS provider with API write access (Cloudflare, Route53, etc.).

- **For `deploy-target` nodes** (passive, SSH push): You don't publish a
  pointer at all. Just push directly via SSH when you want to deploy:
  
  ```bash
  ssh root@myhost.example.com \
    nixos-rebuild switch --flake '.#nixosConfigurations.myhost' \
      --target-host root@myhost.example.com
  ```

### Part 4: The node substitutes and switches

When the node's update trigger fires (a timer tick for `pull-update`, or an SSH
session for `deploy-target`):

1. It reads or receives the pointer to `/nix/store/...-nixos-system-myhost-...`.
2. It asks the cache "do you have this, and is it signed by a key I trust?"
3. The cache proves it (or the node already has it locally from a prior pull).
4. The node runs `nix copy --from <cache> <path>` (download only, verified).
5. It activates live via `switch-to-configuration switch` — **no reboot**.
6. It health-checks (systemd units, optional HTTP endpoint).
7. On health-check failure, it rolls back to the last-known-good generation.

All of this happens *on the node*. The producer's job ends at step 2 (push to
cache) and step 3 (publish the pointer or accept an SSH session).

## Tiny worked example: GitHub Actions + Cachix + DNS TXT

Here's a minimal GitHub Action that satisfies the contract:

```yaml
name: build and deploy

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      # Step 1: Build the closure
      - uses: nixos/nix-installer-action@v4
      - run: nix build .#nixosConfigurations.myhost.config.system.build.toplevel
      
      # Step 2: Sign and push to binary cache
      - uses: cachix/cachix-action@v12
        with:
          name: mycache
          authToken: '${{ secrets.CACHIX_AUTH_TOKEN }}'
      - run: cachix push mycache $(nix-build --no-link .#nixosConfigurations.myhost.config.system.build.toplevel)
      
      # Step 3: Publish DNS TXT pointer
      - run: |
          STORE_PATH=$(nix-instantiate --eval -A nixosConfigurations.myhost.config.system.build.toplevel | tr -d '"')
          # Use your DNS provider's API (this is pseudocode — adapt to your provider)
          # e.g., curl -X POST https://api.dns-provider.com/zones/example.com/records \
          #   -H "Authorization: Bearer ${{ secrets.DNS_API_TOKEN }}" \
          #   -d "type=TXT&name=_deploy.myhost&content=v=1 $STORE_PATH"
```

The node wakes up on the configured interval, reads `_deploy.myhost.example.com`,
substitutes the path, health-checks, and is done. No manual SSH, no per-node
CI configuration, no repeated `nixos-rebuild` commands that risk OOMing the
tiny box.

## What this contract **doesn't** cover

- **Build tool choice:** Use Hydra, a self-hosted CI, GitHub Actions,
  GitLab CI, your beefy laptop — anything that can run `nix build`.
- **Cache backend:** Cachix, a self-hosted `nix serve`, an S3 bucket, any
  HTTP server that speaks the Nix cache protocol.
- **DNS provider:** Cloudflare, Route53, Bind, any DNS API you can reach from
  your build pipeline.
- **Health checks:** nixvps rolls back if health checks fail, but *you* define
  which systemd units matter and (optionally) what HTTP endpoint to probe.
- **Secrets:** Keep your cache signing keys, deploy SSH keys, and DNS API
  tokens in your CI platform's secret store.

## Cross-references

- **`modules/deploy-target.nix`** — configures `nix.settings.substituters`,
  `trusted-public-keys`, and `require-sigs`. Required for any push or pull
  model.
- **`modules/pull-update.nix`** — handles autonomous DNS TXT polling,
  substitution, live switch, health-check rollback. Uses deploy-target's
  cache trust.

## Guideline: size the cache key and closure thoughtfully

A typical nixvps node carries 1–2 GB of store paths. The initial download of a
full system closure (~500 MB to 1 GB, depending on workload) takes a few
minutes on a typical cloud VM uplink. If you add heavy dependencies (e.g., a
full Haskell toolchain), the node's store will fill up and you'll need to
tune `nixvps.tinyVm.gcOlderThan`. Start small, measure, then add.
