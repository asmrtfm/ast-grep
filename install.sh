#!/usr/bin/env bash

[[ "${1,,}" != *(\-)@(h)?(elp) ]] || { cat <<EOL
USAGE
        ./install [ -b|--build ]

SYNOPSIS:
        Optionally build, and install to BOTH user and system-wide.

EOL

  exit 0
}

[[ "${1,,}" != *(\-)@(b)?(uild) ]] || cargo build --release

cp ./target/release/ast-grep ~/.cargo/bin/ast-grep
cp ./target/release/sg ~/.cargo/bin/sg

sudo cp ./target/release/ast-grep /usr/local/bin/ast-grep
sudo cp ./target/release/sg /usr/local/bin/sg
