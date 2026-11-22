#!/usr/bin/env bash
# Builds the bundled reverse-engineering add-on: everything the APK ships that the older
# re-toolchain pack did not (rizin, LLDB, LIEF, Unicorn, tree-sitter, Semgrep, JADX headless MCP)
# plus four JVM libraries as plain files. Runs on the CI runner; nothing here runs on the phone.
#
#   build-addon.sh <out.zip> <work dir>
set -euo pipefail
OUT="$1"
A="$2"
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
rm -rf "$A"; mkdir -p "$A/tree"
T="$A/tree"
P="$T/opt/dsh-re-tools"
mkdir -p "$P/python" "$P/rizin" "$P/jar" "$P/lib" "$P/bin" "$T/usr/local/bin" "$T/etc/profile.d"

# ADDON_CACHE: optional directory of files named by their URL basename; a re-run or an offline
# test then skips the network.
ADDON_CACHE=$(printenv ADDON_CACHE || true)
get() {
  name=$(basename "$1")
  if [ -n "$ADDON_CACHE" ] && [ -f "$ADDON_CACHE/$name" ]; then
    cp -f "$ADDON_CACHE/$name" "$2"
    return 0
  fi
  attempt=0
  while [ "$attempt" -lt 8 ]; do
    attempt=$((attempt+1))
    if curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 30         --speed-limit 4096 --speed-time 60 --max-time 1800 -o "$2.part" "$1"; then
      mv -f "$2.part" "$2"
      return 0
    fi
    sleep $((attempt*2))
  done
  echo "download failed: $1" >&2
  return 1
}

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
# The MCP Kotlin SDK splits into core/client/server on the JVM; the plain -jvm jar is a stub.
get https://repo1.maven.org/maven2/io/modelcontextprotocol/kotlin-sdk-core-jvm/0.16.0/kotlin-sdk-core-jvm-0.16.0.jar "$P/lib/kotlin-sdk-core.jar"
get https://repo1.maven.org/maven2/io/modelcontextprotocol/kotlin-sdk-client-jvm/0.16.0/kotlin-sdk-client-jvm-0.16.0.jar "$P/lib/kotlin-sdk-client.jar"
get https://repo1.maven.org/maven2/io/modelcontextprotocol/kotlin-sdk-server-jvm/0.16.0/kotlin-sdk-server-jvm-0.16.0.jar "$P/lib/kotlin-sdk-server.jar"
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

# ── 侦察/Web 工具（官方 arm64）与自研 connect-scan
mkdir -p "$P/bin" "$P/sqlmap"
for z in subfinder:2.17.0:subfinder_2.17.0_linux_arm64.zip httpx:1.12.0:httpx_1.12.0_linux_arm64.zip dnsx:1.3.1:dnsx_1.3.1_linux_arm64.zip ; do
  n=$(echo "$z" | cut -d: -f1); v=$(echo "$z" | cut -d: -f2); f=$(echo "$z" | cut -d: -f3)
  get "https://github.com/projectdiscovery/$n/releases/download/v$v/$f" "/tmp/$f"
  unzip -oq "/tmp/$f" -d "$P/bin"
done
get https://github.com/ffuf/ffuf/releases/download/v2.3.0/ffuf_2.3.0_linux_arm64.tar.gz /tmp/ffuf.tgz
tar -xzf /tmp/ffuf.tgz -C "$P/bin" ffuf
get https://github.com/sqlmapproject/sqlmap/archive/refs/tags/1.10.2.tar.gz /tmp/sqlmap.tgz
tar -xzf /tmp/sqlmap.tgz -C "$P/sqlmap" --strip-components=1
get https://files.pythonhosted.org/packages/8a/26/548439f5192e496fff7f54d41d8762fa8f3712d53c8441b9f57d7c7a8310/volatility3-2.28.2-py3-none-any.whl /tmp/volatility3.whl
unzip -q -o /tmp/volatility3.whl -d "$P/python"
cp "$(dirname "$0")/connect_scan.py" "$P/bin/connect-scan"
chmod 755 "$P/bin/subfinder" "$P/bin/httpx" "$P/bin/dnsx" "$P/bin/ffuf" "$P/bin/connect-scan"
# The app copies regular files only, so every link becomes a real file: the rizin multi-call
# names become argv[0]-preserving wrappers, everything else is dereferenced (small libs/binaries).
find "$T" -xtype l -delete 2>/dev/null || true
for l in "$P"/rizin/bin/rz-* ; do
  [ -L "$l" ] || continue
  n=$(basename "$l")
  printf '#!/bin/bash\nexec -a %s /opt/dsh-re-tools/rizin/bin/rizin "$@"\n' "$n" > "$l.tmp"
  chmod 755 "$l.tmp"
  mv -f "$l.tmp" "$l"
done
find "$T" -type l -print0 | while IFS= read -r -d '' l ; do
  t=$(readlink -f "$l" || true)
  if [ -z "$t" ] || [ ! -f "$t" ]; then rm -f "$l"; continue; fi
  sz=$(stat -c %s "$t")
  if [ "$sz" -le 33554432 ]; then
    cp -Lf "$l" "$l.tmp" && chmod 755 "$l.tmp" && mv -f "$l.tmp" "$l"
  else
    rm -f "$l"
  fi
done
find "$T" -type l | wc -l

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
files = 0
size = 0
for r, _, fs in os.walk(tree):
    for f in fs:
        p = os.path.join(r, f)
        if os.path.islink(p):
            continue
        files += 1
        size += os.path.getsize(p)
json.dump({"v": 1, "files": files, "bytes": size}, open(os.path.join(a, "manifest.json"), "w"))
print("add-on files", files, "bytes", size)
PY

( cd "$A" && zip -q -r -y "$OUT" tree exec.txt manifest.json )
ls -l "$OUT"
