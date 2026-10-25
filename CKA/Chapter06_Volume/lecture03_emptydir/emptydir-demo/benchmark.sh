#!/bin/sh
# Runs INSIDE a pod (or locally) against a target directory.
# Usage: sh benchmark.sh /scratch
# Three tests:
#   1. Large sequential write, forced to storage (fsync)
#   2. Large sequential read
#   3. Many small files, each fsync'd  (where disk really hurts)

DIR="${1:-/scratch}"
SIZE_MB="${SIZE_MB:-256}"
SMALL_FILES="${SMALL_FILES:-1000}"

now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

echo "=== Target: $DIR ==="
df -h "$DIR" | tail -1 | awk '{print "Filesystem: "$1"   Size: "$2}'
mount | grep " $DIR " | head -1 | awk '{print "Mount type: "$5}'
echo

# 1. Sequential write with fsync
start=$(now_ms)
dd if=/dev/zero of="$DIR/bigfile" bs=1M count="$SIZE_MB" conv=fsync 2>/dev/null
end=$(now_ms)
w=$((end - start)); [ "$w" -eq 0 ] && w=1
echo "1) Sequential write ${SIZE_MB}MB (fsync): ${w} ms  (~$(( SIZE_MB * 1000 / w )) MB/s)"

# 2. Sequential read
start=$(now_ms)
dd if="$DIR/bigfile" of=/dev/null bs=1M 2>/dev/null
end=$(now_ms)
r=$((end - start)); [ "$r" -eq 0 ] && r=1
echo "2) Sequential read  ${SIZE_MB}MB:         ${r} ms  (~$(( SIZE_MB * 1000 / r )) MB/s)"
echo "   (note: disk reads may be served from page cache, so this gap is often small)"
rm -f "$DIR/bigfile"

# 3. Small files, each fsync'd
mkdir -p "$DIR/small"
start=$(now_ms)
i=1
while [ "$i" -le "$SMALL_FILES" ]; do
  dd if=/dev/zero of="$DIR/small/f$i" bs=4k count=1 conv=fsync 2>/dev/null
  i=$((i + 1))
done
end=$(now_ms)
s=$((end - start)); [ "$s" -eq 0 ] && s=1
echo "3) ${SMALL_FILES} x 4KB files (fsync each): ${s} ms  (~$(( SMALL_FILES * 1000 / s )) files/s)"
rm -rf "$DIR/small"

echo "RESULT $w $r $s"
