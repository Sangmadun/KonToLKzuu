<p align="center">
  <img src="https://img.shields.io/badge/Kernel-4.14__Non--GKI-1e293b?style=for-the-badge&logo=linux&logoColor=white" />
  <img src="https://img.shields.io/badge/Device-camellia%2Fn-38bdf8?style=for-the-badge&logo=android&logoColor=black" />
  <img src="https://img.shields.io/badge/CI-GitHub_Actions-22c55e?style=for-the-badge&logo=githubactions&logoColor=white" />
</p>

<h3 align="center">⚡ <code>KonToLKzuu</code> — Kernel & KSU Build Pipeline</h3>

<p align="center">
  <i>"It compiled on GitHub Actions, so it's feature-complete, not buggy... right?"</i> 💀
</p>

<p align="center">
  Personal CI/CD engine for compiling 4.14 non-GKI Linux kernels & KernelSU managers for <b>POCO M3 Pro 5G / Redmi Note 10 5G</b> (<code>camellia</code> / MT6833).
</p>

---

## 📦 What This Repo Is

This is the **full source & build pipeline** behind **LotusKernel Camellia v7** — the kernel flashed via
[the binary release](https://github.com/Sangmadun/KonToLKzuu/releases/tag/v20260818-1732).

It contains everything needed to reproduce the build yourself on GitHub Actions:

```
.github/
├── workflows/          # Build kernel, userspace, manager, LPUD, cleanup, upstream watcher
├── actions/            # apply-susfs, inject-features, inject-ft8722, package-anykernel,
│                       # setup-ksu, download-toolchain
├── scripts/            # build_kernel.sh, ksud bootstrap, SUS_MAP 4.14, inline-hook validators, ...
└── manifest/           # repo manifests (kernel base + revision pins)
patches/
├── camellia_v7_full_defconfig   # defconfig used for the v7 build
├── camellia-anykernel/          # AnyKernel3 wrapper (flashable ZIP template)
├── ft8722_driver/               # FocalTech FT8722 touch driver (built-in)
└── susfs_v220/                  # SUSFS 2.2.0 kernel tree for 4.14 (fs/ + security/ + kernel/)
```

## 🛠️ Features Built Into v7

- 🛡️ **KernelSU fork:** ReSukiSU (built-in ksud bootstrap, v4.2.0-rc1 / 35079)
- 🔒 **SUSFS 2.2.0** — SUS Path/Loop, SUS Map, SUS KSTAT, Open Redirect, uname/cmdline spoof, AVC log spoofing
- 🧩 **DroidSpace & OverlayFS** (Mountify / Magic Mount)
- 📡 **Baseband-Guard (BBG)**
- ⚡ **BBR** TCP congestion control, ZSTD/ZRAM, WireGuard, F2FS backport
- 🖐️ **FocalTech FT8722** touch driver compiled in
- 🌐 TTL/HL spoofing (mobile hotspot tethering bypass)
- ⚙️ Proton-Clang / AOSP Clang toolchains, LTO + O3

## 🔧 Build It Yourself

1. **Fork** this repo.
2. Open **Actions → "Build Kernel & Tools (Automated Pipeline)" → Run workflow**.
3. Recommended inputs for a v7-equivalent build:

| Input | Value |
|---|---|
| `build_target` | `both` (kernel + manager) or `kernel_only` |
| `ksu_fork` | `ReSuKISU` |
| `manifest_name` | `camellia` |
| `include_susfs` | ✅ (default) |
| `include_droidspace` | ✅ (default) |
| `include_bbg` | ✅ (default) |
| `include_lpud` | ✅ (default) |

4. Wait for the run to finish — artifacts (flashable AnyKernel3 ZIP + Manager APK) are uploaded to the run page / Releases.

> The kernel source itself is **not vendored here** (keeps the repo small). It's pulled by the manifest:
> `camellia-devs/kernel_xiaomi_mt6833` @ `56fa4c938c73d721341bba905790a46259192c60` (flyme branch).
> See `.github/manifest/camellia.xml`.

## 📥 Prebuilt Binaries

| Release | Contents |
|---|---|
| [v20260818-1732](https://github.com/Sangmadun/KonToLKzuu/releases/tag/v20260818-1732) | LotusKernel v7 final ZIP + SHA256 + ReSukiSU Manager APK + cert |
| [v7-camellia-universal](https://github.com/Sangmadun/KonToLKzuu/releases/tag/v7-camellia-universal) | Earlier universal build |

## 🤝 Credits

[`camellia-devs`](https://github.com/camellia-devs/kernel_xiaomi_mt6833) • [`LinuxxPU`](https://github.com/ahmad24shargh/LinuxxPU) • [`GKI_KernelSU_SUSFS`](https://github.com/WildKernels/GKI_KernelSU_SUSFS) • [`TheWildJames`](https://github.com/TheWildJames) • [`SUKISU`](https://github.com/ShirkNeko) • [`xxKSU`](https://github.com/backslashxx) • [`KernelSU`](https://github.com/tiann/KernelSU) • [`ReSukiSU`](https://github.com/ReSukiSU/ReSukiSU) • [`AnyKernel3`](https://github.com/osm0sis/AnyKernel3) • [`Baseband-guard`](https://github.com/vc-teahouse/Baseband-guard)

---

> ⚠️ Flashing a custom kernel carries risk (bootloop / data loss). Always keep a backup and a way to flash back to stock. This project is provided as-is; use at your own risk.
