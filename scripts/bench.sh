#!/usr/bin/env bash
# Benchmark Groth16 proving with this repo's portable rapidsnark against the official prebuilt one.
#
# Runs upstream logos-blockchain's own `prove` benches (PoL, PoQ, PoC, zksign) twice: once linked
# against the official rapidsnark archives (downloaded by the rapidsnark build script), once against
# the portable archives built by ./nix/rapidsnark-portable. On a CPU without ADX/BMI2 the official
# run would die of SIGILL, so it is skipped there.
#
# Needs: nix (flakes), a Rust toolchain (cargo), clang/libclang, git, curl, tar.
# Usage:   scripts/bench.sh [workdir]        (default workdir: ./bench-work)
# Env:     SAMPLES=10  samples per bench (each sample is one proof; ~12 s per proof on a Celeron N2820)
#          JOBS=<n>    cargo build jobs (default: all cores)
set -euo pipefail

LB_TAG=0.3.4          # logos-blockchain release this module is built from
CIRCUITS_TAG=v0.5.7   # circuits that release pins (lbc-* tags in its Cargo.toml)
SAMPLES=${SAMPLES:-10}
JOBS=${JOBS:-$(nproc)}
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mkdir -p "${1:-bench-work}" && cd "${1:-bench-work}" && pwd)
PROOFS=(pol poq poc zksign)
PKGS=(); for p in "${PROOFS[@]}"; do PKGS+=(-p "logos-blockchain-$p"); done

cd "$WORK"
[ -d logos-blockchain ] || git clone --depth 1 --branch "$LB_TAG" https://github.com/logos-blockchain/logos-blockchain.git
c="logos-blockchain-circuits-$CIRCUITS_TAG-linux-x86_64"
if [ ! -d "$c" ]; then
  curl -fL -o "$c.tar.gz" "https://github.com/logos-blockchain/logos-blockchain-circuits/releases/download/$CIRCUITS_TAG/$c.tar.gz"
  tar xzf "$c.tar.gz"
fi
export LBC_ROOT_DIR="$WORK/$c"
PORTABLE=$(nix build --no-link --print-out-paths "$REPO/nix/rapidsnark-portable#rapidsnark")

variants=(portable)
if grep -qw adx /proc/cpuinfo && grep -qw bmi2 /proc/cpuinfo; then variants=(official portable); fi

run() { # variant, extra cargo args...
  local v=$1; shift
  if [ "$v" = portable ]; then export RAPIDSNARK_LIB_DIR=$PORTABLE; else unset RAPIDSNARK_LIB_DIR; fi
  (cd logos-blockchain && CARGO_TARGET_DIR="$WORK/target-$v" cargo bench "${PKGS[@]}" --bench prove "$@")
}
for v in "${variants[@]}"; do
  echo ">> building $v (logs: $WORK/build-$v.log)" >&2
  run "$v" --no-run -j "$JOBS" >"$WORK/build-$v.log" 2>&1 || { tail -30 "$WORK/build-$v.log"; exit 1; }
done

{
  echo "### Benchmark: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"
  echo
  echo "- logos-blockchain $LB_TAG, circuits $CIRCUITS_TAG, $SAMPLES samples, this repo at $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "- kernel $(uname -r), $(nproc) threads, ADX: $(grep -qw adx /proc/cpuinfo && echo yes || echo no), BMI2: $(grep -qw bmi2 /proc/cpuinfo && echo yes || echo no)"
  echo "- load before run: $(cut -d' ' -f1-3 /proc/loadavg)"
  echo
  echo '```'
  for v in "${variants[@]}"; do
    for p in "${PROOFS[@]}"; do
      echo "===== $v / $p"
      all=("${PKGS[@]}"); PKGS=(-p "logos-blockchain-$p")
      run "$v" -- --sample-count "$SAMPLES" 2>/dev/null
      PKGS=("${all[@]}")
    done
  done
  echo '```'
} | tee "$WORK/report.md"
echo >&2
echo ">> report saved to $WORK/report.md; please paste it into a new issue (Benchmark template)." >&2
