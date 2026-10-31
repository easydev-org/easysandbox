#!/bin/sh
# Prove that the :dev image can actually build things.
#
# A FILE, NOT A YAML HEREDOC. This started life inline in ci.yml and was wrong twice for the same
# reason: every layer of quoting — YAML, shell, then the C compiler — has its own idea of what a
# backslash means. Written here it can be run by hand against a local image, which is what made the
# last mistake obvious.
#
# RUN INSIDE THE CONTAINER (`docker run --entrypoint sh <image> /probe.sh`), so `set -e` fails the
# docker run, which fails the step. Everything below is an assertion that exits non-zero.
set -eu

echo "--- what is here ---"
python3 --version
node --version
npm --version
go version
gcc --version | head -1
git --version
curl --version | head -1
make --version | head -1
jq --version

echo "--- python: the stdlib modules a build actually uses ---"
python3 -c 'import venv, ssl, sqlite3, json, urllib.request; print("python stdlib ok")'

echo "--- a C program: written, compiled, RUN ---"
cat > /tmp/t.c <<'C'
#include <stdio.h>
int main(void) { printf("c-ok\n"); return 0; }
C
gcc -o /tmp/t /tmp/t.c
out="$(/tmp/t)"
[ "$out" = "c-ok" ] || { echo "the compiled program printed '$out', want c-ok" >&2; exit 1; }
echo "compiled and ran: $out"

echo "--- python: a virtualenv, and a round trip through it ---"
python3 -m venv /tmp/venv
out="$(/tmp/venv/bin/python -c 'import json,sys; sys.stdout.write(json.dumps({"ok": True}))')"
[ "$out" = '{"ok": true}' ] || { echo "venv python printed '$out'" >&2; exit 1; }
echo "venv ok: $out"

echo "--- pip can install OUTSIDE a venv (why EXTERNALLY-MANAGED was removed) ---"
python3 -m pip install --quiet --disable-pip-version-check six
python3 -c 'import six; print("pip installed six", six.__version__)'

echo "--- go builds and runs ---"
mkdir -p /tmp/g && cd /tmp/g && go mod init probe >/dev/null 2>&1
cat > main.go <<'GO'
package main

import "fmt"

func main() { fmt.Println("go-ok") }
GO
out="$(go run .)"
[ "$out" = "go-ok" ] || { echo "go printed '$out'" >&2; exit 1; }
echo "go ran: $out"

echo "--- node runs ---"
out="$(node -e 'console.log("node-ok")')"
[ "$out" = "node-ok" ] || { echo "node printed '$out'" >&2; exit 1; }
echo "node ran: $out"

echo "--- npm installs a package (the registry is reachable from inside) ---"
mkdir -p /tmp/n && cd /tmp/n
npm install --silent --no-audit --no-fund left-pad >/dev/null
node -e 'const lp=require("left-pad"); if (lp("x",3)!=="  x") process.exit(1); console.log("npm ok")'

echo "ALL TOOLCHAIN CHECKS PASSED"
