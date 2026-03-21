# Web-App-Lab-Setup-er — Audit & Improvement Checklist

Practical checklist for hardening this repo's code quality, security, and GitHub presence.

---

## Code Quality

- [x] `set -euo pipefail` in setup.sh
- [x] Logging to file (`/tmp/webapp-pentest-lab-install.log`)
- [x] Color-coded output with helper functions
- [x] Pre-flight checks (OS, arch, disk, RAM, network)
- [ ] ShellCheck clean pass (run `shellcheck setup.sh`)
- [ ] Add `trap` cleanup handler for interrupted installs
- [ ] Quote all variable expansions consistently
- [ ] Add `--dry-run` flag for previewing changes without executing

## Security

- [x] Validates root/sudo before running
- [x] Docker containers set to `restart: unless-stopped`
- [ ] Pin Docker images to specific digests instead of `:latest`
- [ ] Verify checksums on ffuf/nuclei binary downloads
- [ ] Add GPG signature verification where available
- [ ] Restrict lab containers to a dedicated Docker network (no host network)
- [ ] Add firewall rules to prevent lab targets from being exposed externally

## GitHub Repo

- [x] MIT License
- [x] Descriptive README with Quick Start
- [x] SVG banner consistent with SkyzFallin repo design system
- [ ] Add `.gitignore` (log files, temp artifacts)
- [ ] Add GitHub Actions CI (ShellCheck lint on push)
- [ ] Add `CONTRIBUTING.md`
- [ ] Tag releases (v1.0, etc.)
- [ ] Add repo topics/tags for discoverability

## Feature Backlog

- [ ] Add WebGoat and bWAPP as optional targets
- [ ] Add Burp Suite Community install automation (where license permits)
- [ ] Support `--update` flag to pull latest Docker images and tool versions
- [ ] Add ZAP (OWASP Zed Attack Proxy) as an optional tool
- [ ] Generate per-target cheat sheets on install
- [ ] Add health check polling loop instead of `sleep 5`
