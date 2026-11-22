#!/usr/bin/env bash
# Builds the bundled reverse-engineering add-on: everything the APK ships that the older
# re-toolchain pack did not (rizin, LLDB, LIEF, Unicorn, tree-sitter, Semgrep, JADX headless MCP)
# plus four JVM libraries as plain files. Runs on the CI runner; nothing here runs on the phone.
#
#   build-addon.sh <out.zip> <work dir>
set -euo pipefail
OUT="$1"
A="$2"
rm -rf "$A"; mkdir -p "$A/tree"
T="$A/tree"
P="$T/opt/dsh-re-tools"
mkdir -p "$P/python" "$P/rizin" "$P/jar" "$P/lib" "$P/bin" "$T/usr/local/bin" "$T/etc/profile.d"

get() { curl -fsSL --retry 6 --retry-delay 3 --max-time 1800 -o "$2" "$1"; }

i=0
for u in \
  https://files.pythonhosted.org/packages/5a/f8/3aba2989bd9f48e796de5260a19acb2af1e6562b147e32a2a26e418a9b58/lief-1.0.0-cp312-abi3-manylinux_2_28_aarch64.whl \
  https://files.pythonhosted.org/packages/33/9f/32d41eb942221bcf4417cdc65537fc8b3bbbd6079d6c161e621f1dd4e94a/unicorn-2.1.4-cp37-abi3-manylinux_2_17_aarch64.manylinux2014_aarch64.whl \
  https://files.pythonhosted.org/packages/e7/b2/9dc423a8cb2e57e2ee982bcfd44fe44e37d7ae2a7ba8e03d93bc6a7b8fb2/tree_sitter-0.26.1-cp312-cp312-manylinux2014_aarch64.manylinux_2_17_aarch64.manylinux_2_28_aarch64.whl \
  https://files.pythonhosted.org/packages/20/6c/1855a65c9d6b50600f7a68e0182153db7cb12ff81fdebd93e87851dfdd8f/tree_sitter_languages-1.10.2-cp312-cp312-manylinux_2_17_aarch64.manylinux2014_aarch64.whl \
  https://files.pythonhosted.org/packages/ef/fa/3fe2cef7a821992b0b1ac00a0d9acf3944fe2cf8ce5840ae6331e702b70a/semgrep-1.186.0-cp310.cp311.cp312.cp313.cp314.py310.py311.py312.py313.py314-none-manylinux_2_34_aarch64.whl ; do
  i=$((i+1))
  get "$u" "/tmp/addon-w$i.whl"
  unzip -q -o "/tmp/addon-w$i.whl" -d "$P/python"
done
# A wheel may keep its payload under <name>.data/purelib (semgrep does); pip would move it.
for d in "$P/python"/*.data ; do
  [ -d "$d" ] || continue
  [ -d "$d/purelib" ] && cp -a "$d/purelib/." "$P/python/"
  [ -d "$d/platlib" ] && cp -a "$d/platlib/." "$P/python/"
  [ -d "$d/scripts" ] && mkdir -p "$P/bin" && cp -a "$d/scripts/." "$P/bin/"
  rm -rf "$d"
done

get https://github.com/rizinorg/rizin/releases/download/v0.9.1/rizin-v0.9.1-android-aarch64.tar.gz /tmp/addon-rizin.tgz
mkdir -p /tmp/addon-rizin && tar -xzf /tmp/addon-rizin.tgz -C /tmp/addon-rizin
RZ=$(dirname "$(dirname "$(find /tmp/addon-rizin -type f -name rizin | head -1)")")
test -n "$RZ"
cp -a "$RZ"/. "$P/rizin/"

for d in lldb-18_18.1.3-1 liblldb-18_18.1.3-1 python3-lldb-18_18.1.3-1 ; do
  get "http://ports.ubuntu.com/ubuntu-ports/pool/universe/l/llvm-toolchain-18/""$d""_arm64.deb" "/tmp/addon-$d.deb"
  dpkg-deb -x "/tmp/addon-$d.deb" /tmp/addon-lldb
done
cp -a /tmp/addon-lldb/. "$T/"
# LLDB wants the narrow ncurses/panel sonames; the rootfs ships only the wide ones.
get "http://ports.ubuntu.com/ubuntu-ports/pool/main/n/ncurses/libncurses6_6.4+20240113-1ubuntu2_arm64.deb" /tmp/addon-ncurses.deb
dpkg-deb -x /tmp/addon-ncurses.deb /tmp/addon-lldb2
cp -a /tmp/addon-lldb2/. "$T/"

get https://github.com/1013503897/jadx-headless-mcp/releases/download/v0.8.0/jadx-headless-mcp-0.8.0-all.jar "$P/jar/jadx-headless-mcp.jar"

get https://repo1.maven.org/maven2/org/eclipse/jgit/org.eclipse.jgit/7.8.1.202611041320-r/org.eclipse.jgit-7.8.1.202611041320-r.jar "$P/lib/org.eclipse.jgit.jar"
get https://repo1.maven.org/maven2/org/eclipse/lsp4j/org.eclipse.lsp4j/1.0.0/org.eclipse.lsp4j-1.0.0.jar "$P/lib/org.eclipse.lsp4j.jar"
get https://repo1.maven.org/maven2/io/modelcontextprotocol/kotlin-sdk-jvm/0.16.0/kotlin-sdk-jvm-0.16.0.jar "$P/lib/kotlin-sdk-jvm.jar"
get https://repo1.maven.org/maven2/io/github/Rosemoe/sora-editor/editor/0.23.6/editor-0.23.6.aar "$P/lib/sora-editor.aar"

# A dangling link would fail the app's copy; the LLDB Python bindings are not needed.
rm -rf "$T/usr/lib/llvm-18/lib/python3.12/site-packages/lldb" 2>/dev/null || true
find "$T" -xtype l -delete 2>/dev/null || true

# Trim what only wastes space in the APK: static archives, bytecode, debug symbols.
find "$P/python" -name '*.a' -delete 2>/dev/null || true
find "$P/python" -name '*.pyc' -delete 2>/dev/null || true
strip --strip-unneeded "$P/python/semgrep/bin/semgrep-core" 2>/dev/null || true

cat > "$P/bin/rizin" <<'EOS'
#!/bin/sh
LD_LIBRARY_PATH="/opt/dsh-re-tools/rizin/lib:/opt/dsh-re-tools/rizin/lib64:$LD_LIBRARY_PATH"
export LD_LIBRARY_PATH
exec /opt/dsh-re-tools/rizin/bin/rizin "$@"
EOS
cat > "$P/bin/rz-bin" <<'EOS'
#!/bin/sh
LD_LIBRARY_PATH="/opt/dsh-re-tools/rizin/lib:/opt/dsh-re-tools/rizin/lib64:$LD_LIBRARY_PATH"
export LD_LIBRARY_PATH
exec /opt/dsh-re-tools/rizin/bin/rz-bin "$@"
EOS
cat > "$P/bin/lldb" <<'EOS'
#!/bin/sh
exec /usr/lib/llvm-18/bin/lldb "$@"
EOS
cat > "$P/bin/lldb-server" <<'EOS'
#!/bin/sh
exec /usr/lib/llvm-18/bin/lldb-server "$@"
EOS
cat > "$P/bin/jadx-mcp" <<'EOS'
#!/bin/sh
JAVA_HOME=/opt/dsh-re-tools/runtime/jdk21
export JAVA_HOME
exec "$JAVA_HOME/bin/java" -jar /opt/dsh-re-tools/jar/jadx-headless-mcp.jar "$@"
EOS
cat > "$P/bin/semgrep" <<'EOS'
#!/bin/sh
PYTHONPATH="/opt/dsh-re-tools/python:$PYTHONPATH"
export PYTHONPATH
exec /opt/python/bin/python3.12 -m semgrep "$@"
EOS
cat > "$T/etc/profile.d/61-dsh-re-addon.sh" <<'EOS'
# Reverse-engineering add-on: rizin, LLDB, LIEF, Unicorn, tree-sitter, Semgrep, JADX headless MCP.
PATH="/opt/dsh-re-tools/bin:$PATH"
PYTHONPATH="/opt/dsh-re-tools/python:$PYTHONPATH"
export PATH PYTHONPATH
EOS

ln -sf /opt/dsh-re-tools/bin/rizin "$T/usr/local/bin/rizin"
ln -sf /opt/dsh-re-tools/bin/lldb "$T/usr/local/bin/lldb"
ln -sf /opt/dsh-re-tools/bin/lldb-server "$T/usr/local/bin/lldb-server"
ln -sf /opt/dsh-re-tools/bin/semgrep "$T/usr/local/bin/semgrep"
ln -sf /opt/dsh-re-tools/bin/jadx-mcp "$T/usr/local/bin/jadx-mcp"

: > "$A/exec.txt"
for f in "$P/bin/rizin" "$P/bin/rz-bin" "$P/bin/lldb" "$P/bin/lldb-server" "$P/bin/jadx-mcp" "$P/bin/semgrep" ; do
  chmod 755 "$f"
  echo "opt/dsh-re-tools/bin/$(basename "$f")" >> "$A/exec.txt"
done
find "$T" -type f -path '*/usr/bin/*' -print0 > /tmp/addon-exec.bin
find "$T" -type f -path '*/usr/libexec/*' -print0 >> /tmp/addon-exec.bin
find "$T" -type f -path '*/rizin/bin/*' -print0 >> /tmp/addon-exec.bin
while IFS= read -r -d '' f ; do
  chmod 755 "$f"
  echo "$f" | sed "s#^$T/##" >> "$A/exec.txt"
done < /tmp/addon-exec.bin
sort -u "$A/exec.txt" -o "$A/exec.txt"

python3 - "$A" <<'PY'
import json, os, sys
a = sys.argv[1]
tree = os.path.join(a, "tree")
files = sum(len(f) for _, _, f in os.walk(tree))
size = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(tree) for f in fs)
json.dump({"v": 1, "files": files, "bytes": size}, open(os.path.join(a, "manifest.json"), "w"))
print("add-on files", files, "bytes", size)
PY

( cd "$A" && zip -q -r -y "$OUT" tree exec.txt manifest.json )
ls -l "$OUT"
