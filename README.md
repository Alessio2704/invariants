# Invariants

Architecture constraints as code, proven by red/green fixtures, and locked with Touch ID SSH signatures.

## Overview

`invariants` enables teams to define architectural rules as executable code (Swift or TypeScript), prove each rule with deterministic fixtures before activation, and cryptographically lock the active rule set with Secure Enclave Touch ID signatures.

AI coding agents can modify application code freely, but cannot weaken, bypass, or tamper with the architectural checks that judge the code.

## Threat Model

The agent is **sloppy, not malicious**. It runs as the owner's macOS user and can write any file the owner can. Typical failure modes:
- Weakening an invariant check to make a PR pass
- Adding exclusions or allowlist entries silently
- Deleting or modifying a failing fixture
- Disabling git hooks or restoring old registries

Each failure mode is either **ineffective** (signed or root-owned content is enforced) or **visible and blocking**.

## Trust Anchors (Root-Owned)

Trust anchors are root-owned and change only via `sudo` (Touch ID):
- `/usr/local/invariants/versions/<v>/`: Engine binary and kits (`kit-swift`, `kit-ts`)
- `/usr/local/invariants/current`: Symlink to active engine version
- `/usr/local/invariants/allowed_signers`: Owner's trusted SSH public key
- `/usr/local/invariants/floors/<repo-id>`: Monotonically increasing floor version per project

## Rule Lifecycle

1. **Scaffold Draft:**
   ```bash
   invariants new <id> --targets swift,ts
   ```
2. **Write Fixtures First (The Spec):**
   - Red fixtures in `should_fail/<target>/` with `// expect: CODE` annotations.
   - Green fixtures in `should_pass/<target>/`.
3. **Implement Rule:**
   - Write AST checks in `rule.swift` or `rule.ts`.
4. **Test Working Tree:**
   ```bash
   invariants test <id>
   ```
5. **Lock & Activate:**
   ```bash
   invariants add <id>
   ```
   Requires owner Touch ID signature.
6. **Continuous Enforcement:**
   Every git commit and push runs `invariants check`.
7. **Rule Modifications:**
   Changes go through `invariants update <id>` + weakening detection report + Touch ID signature.

## Manual Recovery

Trust resides in standard OpenSSH signatures, not proprietary formats. You can inspect and sign registries by hand:
```bash
# Verify signature
ssh-keygen -Y verify -f /usr/local/invariants/allowed_signers -I owner -n invariants -s registry.lock.sig < registry.lock

# Sign registry manually
ssh-keygen -Y sign -f "$(git config user.signingkey)" -n invariants registry.lock
```

## Accepted Risks

| Risk | Why accepted | Mitigation |
|---|---|---|
| `--no-verify` / `core.hooksPath` bypass in a project | cannot be solved locally without a second user | agent deny-list; tooling rules detect it on the next run; the floor still applies |
| Force-push with `--no-verify` | no server-side branch protection on GitHub Free private repos | deny-list; root floor refuses any later registry below max signed |
| Rule build cache poisoning | deliberate, needs knowledge of cache layout | optional future root-built cache |
| Blind Touch ID approval | human factor | the one human rule: review diffs before touching sensor |
