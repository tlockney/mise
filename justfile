set shell := ["bash", "-uc"]

export MISE_DATA_DIR := "/tmp/mise"
export PATH := env_var_or_default("CARGO_TARGET_DIR", justfile_directory() / "target") / "debug:" + env_var("PATH")
export RUST_TEST_THREADS := "1"

# defaults to `just test`
default: test

alias b := build
alias e := test-e2e
alias t := test
alias l := lint
alias lf := lint-fix

# just `cargo build`
build *args:
    cargo build --all-features {{ args }}

watch:
    watchexec -w src -- just build

# run all test types
test *args: (test-unit args) test-e2e lint

# run the rust "unit" tests
test-unit *args:
    cargo test --all-features {{ args }}

# runs the E2E tests in ./e2e

# specify a test name to run a single test
test-e2e TEST=("all"): build
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{ TEST }}" = all ]; then
        ./e2e/run_all_tests
    else
        FILES="$(fd {{ TEST }} e2e/)"
        for FILE in $FILES; do
            ./e2e/run_test "$FILE"
        done
    fi

# run unit tests w/ coverage
test-coverage:
    #!/usr/bin/env bash
    echo "::group::Setup"
    set -euxo pipefail
    source <(cargo llvm-cov show-env --export-prefix)
    cargo llvm-cov clean --workspace
    if [[ -n "${MISE_GITHUB_BOT_TOKEN:-}" ]]; then
    	export GITHUB_API_TOKEN="$MISE_GITHUB_BOT_TOKEN"
    fi
    export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$PWD/target}"
    export PATH="${CARGO_TARGET_DIR}/debug:$PATH"

    echo "::group::Build w/ coverage"
    cargo build --all-features
    echo "::endgroup::"
    ./e2e/run_all_tests
    if [[ "${TEST_TRANCHE:-}" == 0 ]]; then
        echo "::group::Unit tests"
        cargo test --all-features
        echo "::group::render-help render-completions render-mangen"
        just render-help render-completions render-mangen
        echo "::group::Implode"
        mise implode
    elif [[ "${TEST_TRANCHE:-}" == 1 ]]; then
        echo "::group::Self update"
        # TODO: remove this once the task runnner is shipped
        mise self-update -fy || true
    fi
    echo "::group::Render lcov report"
    cargo llvm-cov report --lcov --output-path lcov.info

# delete built files
clean:
    cargo clean
    rm -f lcov.info
    rm -rf e2e/.{asdf,config,local,mise}/
    rm -rf target
    rm -rf *.profraw
    rm -rf coverage

scripts := "scripts/*.sh e2e/{test_,run_}* e2e/*.sh"

# clippy, cargo fmt --check, and just --fmt
lint:
    cargo clippy -- -Dwarnings
    cargo fmt --all -- --check
    mise x shellcheck@latest -- shellcheck -x {{ scripts }}
    mise x shfmt@latest -- shfmt -d {{ scripts }}
    just --unstable --fmt --check
    MISE_EXPERIMENTAL=1 mise x npm:prettier@latest -- prettier -c $(git ls-files '*.yml' '*.yaml')
    MISE_EXPERIMENTAL=1 mise x npm:markdownlint-cli@latest -- markdownlint .

# runs linters but makes fixes when possible
lint-fix:
    cargo clippy --fix --allow-staged --allow-dirty -- -Dwarnings
    cargo fmt --all
    mise x shellcheck@latest -- shellcheck -x {{ scripts }}
    mise x shfmt@latest -- shfmt -w {{ scripts }}
    just --unstable --fmt
    MISE_EXPERIMENTAL=1 mise x npm:prettier@latest -- prettier -w $(git ls-files '*.yml' '*.yaml')
    MISE_EXPERIMENTAL=1 mise x npm:markdownlint-cli@latest -- markdownlint --fix .

render-all: render-help render-completions render-mangen

# regenerate docs/cli-reference.md
render-help: build
    NO_COLOR=1 mise render-help
    mise x node@latest -- npx markdown-magic

# regenerate shell completion files
render-completions: build
    NO_COLOR=1 mise render-completion bash > completions/mise.bash
    NO_COLOR=1 mise render-completion zsh > completions/_mise
    NO_COLOR=1 mise render-completion fish > completions/mise.fish

# regenerate manpages
render-mangen: build
    NO_COLOR=1 mise render-mangen

# called by lefthook precommit hook
pre-commit: render-all lint
    git add README.md
    git add docs/cli-reference.md
    git add completions
    git add man
