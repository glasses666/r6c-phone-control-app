#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage:
  patch-openeuicc.sh OPENEUICC_CHECKOUT [--build-debug]

Adds the R6C CLI ContentProvider to an OpenEUICC/EasyEUICC app-unpriv checkout.
The provider is exported but protected by android.permission.DUMP, so adb shell
can call it while ordinary apps cannot.
EOF
}

checkout="${1:-}"
[ -n "$checkout" ] || {
  usage >&2
  exit 2
}
shift || true

build_debug=false
case "${1:-}" in
  --build-debug)
    build_debug=true
    ;;
  '')
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    echo "ERROR unknown option: $1" >&2
    usage >&2
    exit 2
    ;;
esac

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
checkout="$(CDPATH= cd -- "$checkout" && pwd)"
manifest="$checkout/app-unpriv/src/main/AndroidManifest.xml"
source_file="$script_dir/EuiccCliProvider.kt"
snippet_file="$script_dir/AndroidManifest.snippet.xml"
dest_file="$checkout/app-unpriv/src/main/java/im/angry/openeuicc/cli/EuiccCliProvider.kt"

[ -f "$manifest" ] || {
  echo "ERROR app-unpriv manifest not found: $manifest" >&2
  exit 1
}
[ -f "$source_file" ] || {
  echo "ERROR provider source not found: $source_file" >&2
  exit 1
}
[ -f "$snippet_file" ] || {
  echo "ERROR provider manifest snippet not found: $snippet_file" >&2
  exit 1
}

mkdir -p "$(dirname -- "$dest_file")"
cp "$source_file" "$dest_file"
echo "patched source: $dest_file"

if grep -q 'im\.angry\.openeuicc\.cli\.EuiccCliProvider' "$manifest"; then
  echo "manifest already contains EuiccCliProvider"
else
  grep -q '</application>' "$manifest" || {
    echo "ERROR manifest has no </application> marker: $manifest" >&2
    exit 1
  }
  tmp="$(mktemp)"
  awk -v snippet="$snippet_file" '
    /<\/application>/ && !inserted {
      while ((getline line < snippet) > 0) {
        print "        " line
      }
      close(snippet)
      inserted = 1
    }
    { print }
    END {
      if (!inserted) exit 42
    }
  ' "$manifest" > "$tmp"
  mv "$tmp" "$manifest"
  echo "patched manifest: $manifest"
fi

if [ "$build_debug" = true ]; then
  (cd "$checkout" && ./gradlew --no-daemon --console=plain :app-unpriv:assembleDebug)
  echo "debug apk: $checkout/app-unpriv/build/outputs/apk/debug/app-unpriv-debug.apk"
fi
