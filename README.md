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
  Personal CI/CD engine for compiling 4.14 non-GKI Linux kernels & KernelSU managers for <b>POCO M3 Pro 5G / Redmi Note 10 5G</b> (<code>camellia</code>).
</p>

---

### ⚠️ Pipeline Truths
*   **Build Success Rate:** 10% (The other 90% is just providing emotional support to the CI/CD runner).
*   **Debug Policy:** If `adb logcat` is blank, I assume the code is perfect and the universe is lying to me.
*   **User Support:** If it bootloops, you are doing it wrong (or my kernel is just having a mid-life crisis).

---

### 🛠️ What's Inside

- 🛡️ **KSU Multi-Fork:** Official KernelSU, KernelSU-Next, xxKSU, & SUKISU support. (Because one root method is never enough to satisfy banking apps).
- 🔒 **Security Hardened:** Pre-patched with SUSFS 4.14 & Baseband-Guard (BBG).
- ⚡ **Toolchains:** Powered by Proton-Clang & AOSP Clang (with 10,000 compiler warnings gracefully ignored).
- ⚙️ **Userspace Rust:** Auto-builds `lpud` binaries because pure C just wasn't spicy enough to break the system.
- 🚀 **Automated CI/CD:** GitHub Actions runner configured to compile and push manager APKs straight to Releases.

---

### 📉 Typical Day of a Kernel Dev
1. **09:00 AM:** Modify 1 line of code in `arch/arm64/configs/camellia_defconfig`.
2. **09:05 AM:** Push to GitHub.
3. **09:30 AM:** GitHub Actions fails (Error: Out of Memory).
4. **10:00 AM:** Cry in Assembly.
5. **11:00 AM:** Deploy anyway and hope nobody notices the lack of WiFi drivers.

---

### 🤝 Credits
*Special thanks to those who actually know what they are doing:*

[`camellia-devs`](https://github.com/camellia-devs/kernel_xiaomi_mt6833) • [`LinuxxPU`](https://github.com/ahmad24shargh/LinuxxPU) • [`GKI_KernelSU_SUSFS`](https://github.com/WildKernels/GKI_KernelSU_SUSFS) • [`TheWildJames`](https://github.com/TheWildJames) • [`SUKISU`](https://github.com/ShirkNeko) • [`xxKSU`](https://github.com/backslashxx) • [`KernelSU`](https://github.com/tiann/KernelSU) • [`AnyKernel3`](https://github.com/osm0sis/AnyKernel3) • [`Baseband-guard`](https://github.com/vc-teahouse/Baseband-guard)

---

<p align="center">
  <br>
  <img src="https://raw.githubusercontent.com/Thagoo/Thagoo/master/github.gif" width="180" />
  <br>
  <code>while (alive) { </code><br>
  <code>  compile(); </code><br>
  <code>  if (bootloop) { cry(); reflash(); } </code><br>
  <code>  else { celebrate(); wait_for_new_bank_update(); }</code><br>
  <code>}</code> 😹
</p>
