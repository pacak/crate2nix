#!/usr/bin/env bash
#
# Regenerates build files and runs tests on them.
# Please use this to validate your pull requests!
#

set -Eeuo pipefail

top="$(readlink -f "$(dirname "$0")")"

if [ -z "${IN_CRATE2NIX_SHELL:-}" -o "${IN_NIX_SHELL:-}" = "impure" ]; then
  export CACHIX="$(which cachix 2>/dev/null || echo "")"
  echo -e "\e[1m=== Entering $top/shell.nix\e[0m" >&2
  exec nix-shell --keep CACHIX --pure "$top/shell.nix" --run "$(printf "%q " $0 "$@")"
fi

echo -e "\e[1m=== Parsing opts for $top/run_tests.sh\e[0m" >&2
options=$(getopt -o '' --long offline,build-test-nixpkgs: -- "$@") || {
    echo "" >&2
    echo "Available options:" >&2
    echo "   --offline            Enable offline friendly operations with out substituters" >&2
    echo "   --build-test-nixpkgs Path to nixpkgs used for the build tests." >&2
    exit 1
}
eval set -- "$options"
NIX_OPTIONS="--option log-lines 100 --show-trace"
REGENERATE_OPTIONS=""
NIX_TESTS_OPTIONS="--out-link ./target/nix-result"
while true; do
    case "$1" in
    --offline)
        NIX_OPTIONS="$NIX_OPTIONS --option substitute false"
        REGENERATE_OPTIONS="$REGENERATE_OPTIONS --offline"
        CACHIX=""
        ;;
    --build-test-nixpkgs)
        shift
        NIX_TESTS_OPTIONS="$NIX_TESTS_OPTIONS --arg buildTestNixpkgs $1"
        ;;
    --)
        shift
        break
        ;;
    esac
    shift
done

# Add other files when we adopt nixpkgs-fmt for them.
cd "$top"
echo -e "\e[1m=== Reformatting nix code\e[0m" >&2
./nixpkgs-fmt.sh \
    ./{,nix/}*.nix \
    ./crate2nix/templates/nix/crate2nix/{*.nix,tests/*.nix} \
    ./sample_projects/*/[[:lower:]]*.nix
cd "$top"/crate2nix
echo "=== Reformatting rust code" >&2
./cargo.sh fmt

cd "$top"
echo -e "\e[1m=== Running nix unit tests\e[0m" >&2
./nix-test.sh ./crate2nix/templates/nix/crate2nix/tests/default.nix || {
    echo "" >&2
    echo "==================" >&2
    echo "$top/nix-test.sh $top/crate2nix/templates/nix/crate2nix/tests/default.nix: FAILED" >&2
    exit 1
}

cd "$top"/crate2nix
echo -e "\e[1m=== Running cargo clippy\e[0m" >&2
./cargo.sh clippy || {
    echo "==================" >&2
    echo "$top/crate2nix/cargo.sh clippy: FAILED" >&2
    exit 2
}

../regenerate_cargo_nix.sh $REGENERATE_OPTIONS || {
    echo "==================" >&2
    echo "$top/regenerate_cargo_nix.sh $REGENERATE_OPTIONS: FAILED" >&2
    exit 3
}

echo -e "\e[1m=== Running cargo test\e[0m" >&2
./cargo.sh test || {
    echo "==================" >&2
    echo "$top/crate2nix/cargo.sh test: FAILED" >&2
    exit 4
}

cd "$top"
echo -e "\e[1m=== Building ./tests.nix (= Running Integration Tests)\e[0m" >&2
nix build -L $NIX_OPTIONS $NIX_TESTS_OPTIONS -f ./tests.nix || {
    echo "==================" >&2
    echo "cd $top" >&2
    echo "nix-build \\" >&2
    echo "  $NIX_OPTIONS $NIX_TESTS_OPTIONS \\" >&2
    echo "   ./tests.nix: FAILED" >&2
    exit 5
}

echo -e "\e[1m=== Checking for uncomitted changes\e[0m" >&2
if test -n "$(git status --porcelain)"; then
    echo ""
    git --no-pager diff HEAD
    echo ""
    echo "!!! repository has uncomitted changes" >&2
    echo "Otherwise, things look good :)"
    exit 6
fi

# Crude hack: check if we have the right to push to the cache
cd "$top"
if test -n "${CACHIX:-}" && test -r ~/.config/cachix/cachix.dhall &&\
 grep -q '"eigenvalue"' ~/.config/cachix/cachix.dhall; then
    echo -e "\e[1m=== Pushing artifacts to eigenvalue.cachix.org \e[0m" >&2
    # we filter for "rust_" to exclude some things that are in the
    # nixos cache anyways
    nix-store -q -R --include-outputs $(nix-store -q -d target/nix-result*) |\
     grep -e "-rust_" |\
     $CACHIX push eigenvalue
fi

echo -e "\e[1m=== SUCCESS (run_tests.sh) \e[0m" >&2
