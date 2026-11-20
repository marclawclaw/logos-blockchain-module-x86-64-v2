# blockchain_module: portable x86-64 build (no ADX/BMI2)

An **unofficial** rebuild of the Logos [`blockchain_module`](https://github.com/logos-blockchain/logos-blockchain-module)
**0.3.4** that runs on x86-64 CPUs without the ADX and BMI2 instruction set extensions.

On those CPUs, the official package crashes as soon as it is loaded:

```
[critical] [logos] [blockchain_module] FATAL: module 'blockchain_module' crashed (signal 4)
[error] [logos] Failed to load module blockchain_module: the module process died on signal 4 before it reported that it had loaded
```

Signal 4 is SIGILL, an illegal instruction. See
[logos-blockchain/logos-blockchain#3743](https://github.com/logos-blockchain/logos-blockchain/issues/3743).

This build fixes that, at the cost of slower proof generation (see [Drawbacks](#drawbacks)).
**Use it only if the official module crashes on your machine.**

## Do I need it?

```sh
grep -qw adx /proc/cpuinfo && grep -qw bmi2 /proc/cpuinfo && echo "use the OFFICIAL module" || echo "use THIS build"
```

The CPUs that need it lack ADX: Intel before Broadwell (2014), including 4th-gen "Haswell" Core i3/i5/i7;
Intel Atom-class Celeron/Pentium chips such as Bay Trail (Silvermont); and AMD before Zen (2017).
This build was made for, and is tested on, an Intel NUC DN2820FYK (Celeron N2820, Bay Trail, x86-64-v2).

## What is different from upstream

One Nix flake input. Everything else is upstream tag `0.3.4`: the same source, the same C API, the same
`blockchain_module_plugin.so`, OpenSSL, boost, manifest and assets.

```nix
rapidsnark-portable.url = "path:./nix/rapidsnark-portable";
logos-blockchain.inputs.rust-rapidsnark.follows = "rapidsnark-portable";
```

The module contains `liblogos_blockchain.so`, the Rust node built as a C library. That library statically links
[rapidsnark](https://github.com/iden3/rapidsnark), iden3's C++ Groth16 prover, and [GMP](https://gmplib.org).
The node uses rapidsnark to prove and verify its circuits: PoL (block leadership), PoQ (Blend), PoC and signatures.

| | Official 0.3.4 | This build |
|---|---|---|
| rapidsnark archives | prebuilt [`rapidsnark-pic-v0.0.8`](https://github.com/logos-blockchain/logos-blockchain-rust-rapidsnark/releases/tag/rapidsnark-pic-v0.0.8) | built from iden3 `v0.0.8` source by [`nix/rapidsnark-portable`](nix/rapidsnark-portable/flake.nix) |
| rapidsnark Fr/Fq field arithmetic | x86-64 assembly (`USE_ASM=ON`): `mulx`/`adcx`/`adox`, which need **BMI2 + ADX** | generic C++ (`USE_ASM=OFF`) |
| GMP | `./configure` tuned to the CI runner's CPU (BMI2/ADX code) | nixpkgs GMP, `--enable-fat`: chooses its CPU-specific code at runtime |
| Rust code | baseline x86-64 | unchanged (baseline x86-64) |
| Platforms other than x86_64-linux | upstream archives | **the same upstream archives** (the arm64 assembly works on every arm64 CPU) |

Checked with `objdump` (instruction counts, x86_64-linux):

| Archive | `adcx`/`adox` (ADX) | `mulx`/`shlx`/… (BMI2) |
|---|---|---|
| official `libfr.a` / `libfq.a` | 210 / 210 | 116 / 116 |
| official `libgmp.a` | 326 | 751 |
| portable `libfr.a` / `libfq.a` / `librapidsnark.a` | **0** | **0** |
| portable `libgmp.a` (fat) | present, only reached after GMP's own `cpuid` check | idem |

The circuits release (`logos-blockchain-circuits` v0.5.7: witness generators and their GMP) has no ADX, BMI2 or AVX
code, so it needs no change. The Nix build fails if ADX or BMI2 instructions appear in the rapidsnark archives.

## Install

### From the fryorcraken catalogue (logosctl)

The package is published in [fryorcraken's Logos module catalogue](https://github.com/fryorcraken/logos-modules)
under the **same name and version as the official module** (`blockchain_module` 0.3.4), so it can stand in for it.
Install it by downloading it **from that catalogue explicitly**, then installing the file:

```sh
logosctl catalog add https://raw.githubusercontent.com/fryorcraken/logos-modules/main/logos-repo.json
logosctl catalog refresh

# Pick the build from this catalogue, not the official one:
logosctl package download blockchain_module --catalog fryorcraken-modules --version 0.3.4 -o ./dl
logosctl install ./dl/blockchain_module*.lgx -y

logosctl package ls --type core          # blockchain_module 0.3.4
logosctl module load blockchain_module   # {"status":"ok"} instead of "signal 4"
```

Then carry on with the [official node guide](https://docs.logos.co/run-a-node) from "Load the module and generate
`user_config.yaml`". Nothing else changes: the same config, ports, keystore and commands.

> **Why not `logosctl install blockchain_module --catalog …`?** Up to and including logosctl 0.3.2, `install` and
> `upgrade` accept `--catalog` and `--root-hash`, then ignore them: only the name and version reach the resolver.
> When two catalogues offer the same name and version, the one released last wins. Only `package download --catalog`
> reliably selects this catalogue's build.

> **Do not run `logosctl package upgrade blockchain_module` afterwards.** It re-resolves across all catalogues, and
> would replace this build with an official one (any later official release, or the same version if it was
> published more recently). That brings the crash back. To update, repeat the `package download` step for the new
> version, once this repo publishes it.

Packages that depend on `blockchain_module`, such as `blockchain_ui`, accept this build: they depend on the name,
not on a signer.

### By hand (any logosctl session)

Download the `.lgx` from this catalogue's
[releases](https://github.com/fryorcraken/logos-modules/releases) (tag `blockchain_module-v0.3.4`) and run
`logosctl install ./blockchain_module-0.3.4.lgx -y`.

### Signature

This catalogue currently publishes **unsigned** packages. Under the default `signature_policy: warn`, logosctl
installs them and logs a warning. Under `signature_policy: require`, it refuses them.

## Drawbacks

- **Slower proof generation.** Generic C++ field arithmetic replaces hand-written assembly, and that arithmetic is
  the core of Groth16 proving. Measured with upstream's own `prove` benchmarks (`zk/proofs/*/benches/prove.rs`,
  logos-blockchain 0.3.4, divan median, one proof per iteration):

  | Proof | Official build, Ryzen 9 7940HS | **This build**, same machine | Slowdown | This build, Celeron N2820 (nuc) |
  |---|---|---|---|---|
  | PoL (block leadership) | 124 ms | 330 ms | **2.7×** | 12.2 s |
  | PoQ, core node (Blend) | 116 ms | 308 ms | **2.7×** | 13.2 s |
  | PoQ, leader (Blend) | 117 ms | 308 ms | **2.6×** | 11.4 s |
  | PoC (claims) | 61 ms | 159 ms | **2.6×** | 7.1 s |
  | zksign (signatures) | 51 ms | 131 ms | **2.5×** | 4.7 s |

  The laptop columns compare the same source with only `RAPIDSNARK_LIB_DIR` changed: 100 samples each, idle machine.
  The N2820 can only run this build (it has no official number). It used 5 samples at `nice 10`, next to a live
  Logos node, so it is somewhat pessimistic.

  **Whether that matters depends on what the node does.** These are the deadlines in logos-blockchain 0.3.4, from reading
  the code (testnet: 1 s slots, about one block every 30 s network-wide, 83 h epochs):

  | Proof | When the node makes it | Deadline | Effect of a slow proof |
  |---|---|---|---|
  | PoL | Each slot it wins; needs stake | **Soft.** It is proved *at* the winning slot, because it needs the current tip state, and a late block is still valid | The block goes out late and can lose the fork race (at 12 s, about 1 in 3 under a simple Poisson model). Slot ticks that arrive while proving are dropped, so wins in those slots are lost |
  | PoQ, core node | Blend cover traffic, roughly 1 proof per *N* s (*N* = number of core nodes), 2 kept ready | None, but the core loop waits for a proof when the buffer is empty | Cover and relayed traffic is delayed. A core node falls behind once a proof takes longer than *N* s |
  | PoQ, leader / PoW | 2 per own block proposal (3 kept ready); 2 per epoch plus 1 per Blend transaction | None | That proposal or transaction is delayed |
  | PoC | User claims leader rewards | None | Slot processing pauses while it proves, as for PoL |
  | zksign | Each wallet transaction, PoW reward claim (1 per 32 tickets) or SDP activity (1 per epoch) | Claims: 600 slots | It runs inside the key-management service, so lottery checks queue behind it |

  In short:
  - **~0.3–1 s per proof** (this build on a modern CPU, or a decent pre-Broadwell desktop): fine for every role. A
    block producer pays a small orphan risk of a few percent.
  - **~10+ s per proof** (this build on a Celeron/Atom such as the N2820):
    - fine for an **unfunded edge node**: it syncs, relays, mines PoW and makes a handful of proofs per epoch;
    - poor for a **staked block producer**: late blocks are often orphaned and wins are missed;
    - not viable as a **Blend core node** while the network has only a few core nodes.

  Proof verification, and therefore syncing, is much less affected than proving. On a CPU that *can* run the
  official build, this build is simply ~2.6× slower at proving, so do not use it there.
- **Unofficial and unsigned.** It is built from upstream source by this repo's flake, but it is not released or
  signed by the Logos Blockchain team. You are trusting this repo and the catalogue's CI.
- **Same name as the official module.** logosctl records no install source. `package upgrade`, or a plain
  `install` by name, can swap this build and the official one either way, depending on version and upload time
  (see [Install](#install)). `logosctl search` lists both copies with no catalogue column, so they look identical.
- **Follows upstream with a delay.** Each upstream release has to be merged here and republished. The
  `rust-rapidsnark` revision in [`nix/rapidsnark-portable/flake.nix`](nix/rapidsnark-portable/flake.nix) must match
  the one logos-blockchain pins for that release.
- **Only linux-amd64 changes.** The other variants are upstream's, rebuilt by this flake.

## Way forward

The goal is for this repo to become unnecessary. Options, roughly from best to least good:

1. **Runtime dispatch in rapidsnark (recommended upstream fix).** Link both the assembly and the generic Fr/Fq
   arithmetic, and choose one once at startup with `cpuid` (ADX + BMI2 present → assembly). Modern CPUs keep full
   speed, old CPUs work, and there is still one package, one name and one signature. This is how GMP (`--enable-fat`),
   OpenSSL, libsodium, BLAKE3 and glibc's string functions handle the same problem. It needs a change to the rapidsnark
   build or the rust-rapidsnark wrapper (two copies of the Fr/Fq symbols, under different names, behind a
   function-pointer table).
2. **CPU variants in the Logos package format.** Today a package has one variant per platform (`linux-amd64`,
   `linux-arm64`, `darwin-arm64`), and the installer has no CPU dimension. A variant such as
   `linux-amd64+adx,bmi2`, with the installer falling back to `linux-amd64` when the CPU lacks those features, would
   let one package carry both builds. That helps every module with hot native code, not only this one. Note:
   **key the variant on CPU features, not on x86-64 psABI levels.** ADX is in no psABI level: `x86-64-v3` (AVX2,
   BMI1/2, FMA…) does not include it, and a Haswell CPU is v3 without ADX. A "v3" variant of the official build would
   still crash on the very CPU in #3743. Trade-offs: larger packages (two copies of an ~80 MB library), plus a
   package-format, installer and release-tooling change.
3. **An official portable build under a different name**, e.g. `blockchain_module_portable`. It is simple and needs
   no tooling change, but every dependent (UI, docs, apps) has to learn the second name.
4. **In every case: a clear startup check.** #3743 itself asks for this: detect a missing ADX/BMI2 and print
   "ADX not supported, you need Broadwell+/Zen" instead of dying on signal 4.

Related logosctl gaps worth fixing whatever the choice: `install`/`upgrade` should honour `--catalog` and
`--root-hash`, and the installed state should record the source catalogue so `upgrade` stays there.

### How Linux distributions handle this

- **Baseline builds.** Debian/Ubuntu `amd64` and Fedora `x86_64` compile packages for the original x86-64
  (v1), so they run everywhere. Enterprise distributions raise the floor instead: RHEL 9 requires x86-64-v2 and RHEL 10
  x86-64-v3, and AlmaLinux ships a v2 rebuild of 10 for older hardware.
- **Runtime dispatch ("fat") for hot code.** This is the standard answer for arithmetic and crypto libraries, and
  it is what this repo uses for GMP:
  - checked here: Fedora 43's `libgmp.so.10` is a fat build (it contains GMP's `cpuvec` dispatch table and the
    vendor/CPU detection);
  - checked here: Ubuntu 22.04's is a plain baseline build (no dispatch, and no ADX/BMI2 instructions at all);
  - OpenSSL picks ADX/BMI2 bignum code at runtime, and glibc selects optimised string functions per CPU through
    IFUNC.
- **Per-CPU-level variants are newer and opt-in.**
  - glibc's `glibc-hwcaps` lets a package install extra copies of a library under
    `/usr/lib64/glibc-hwcaps/x86-64-v3/`, which the dynamic loader prefers on capable CPUs; openSUSE uses this for
    selected libraries.
  - Ubuntu 25.10 introduced `amd64v3` architecture-variant packages, which apt picks automatically.
  - Arch-based CachyOS ships separate v3/v4 repositories.
  - All of these are keyed on psABI levels, which is fine for "compiled with `-march=x86-64-v3`" but not for an
    ADX requirement (see option 2).

In short: distributions ship portable binaries, and put the speed into runtime dispatch inside the few libraries
where it matters. Level-based variants are an optimisation on top, not a correctness mechanism. That is why option 1 is
the cleanest fix here, and why a variant mechanism (option 2) would need to be feature-based to be correct.

## Build

Needs Nix with flakes. The first build compiles the Rust node, which takes about 20 minutes on 12 cores.

```sh
nix build .#lgx-portable          # -> result/*.lgx, what the catalogue publishes
nix build ./nix/rapidsnark-portable#rapidsnark   # just the portable archives (checks for ADX/BMI2)
```

The catalogue's release workflow ([logos-modules-release-action](https://github.com/logos-co/logos-modules-release-action))
builds `.#lgx-portable` from this repo's `metadata.json`, like any other module.

### Updating to a new upstream release

```sh
git fetch upstream --tags
git merge <new-tag>               # keep this repo's README.md, nix/ and the 2 flake.nix lines
# set upstream.url in nix/rapidsnark-portable/flake.nix to the rust-rapidsnark rev the new
# logos-blockchain release pins (its flake.nix / Cargo.toml), and `version` to its RAPIDSNARK_VERSION
nix flake update rapidsnark-portable
nix build .#lgx-portable
```

Then bump the catalogue's submodule and run its "Release blockchain_module" workflow.

Upstream's README is kept as [UPSTREAM-README.md](UPSTREAM-README.md).

## License

Same as upstream: MIT or Apache-2.0 ([LICENSE-MIT](LICENSE-MIT), [LICENSE-APACHE-v2](LICENSE-APACHE-v2)).
