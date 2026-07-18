#!/bin/sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(CDPATH= cd -- "$script_dir/../.." && pwd)"
src_dir="$script_dir/src"
build_dir="$script_dir/build"
classes_dir="$build_dir/classes"
out_dex="$build_dir/euicc-app-process-cli.dex"

android_jar="${ANDROID_JAR:-}"
d8_jar="${D8_JAR:-}"
android_home="${ANDROID_HOME:-}"
android_sdk_root="${ANDROID_SDK_ROOT:-}"

if [ -z "$android_jar" ]; then
  for candidate in \
    /opt/homebrew/share/android-commandlinetools/platforms/android-35/android.jar \
    /opt/homebrew/share/android-commandlinetools/platforms/android-34/android.jar \
    "$android_home/platforms/android-35/android.jar" \
    "$android_sdk_root/platforms/android-35/android.jar"
  do
    if [ -f "$candidate" ]; then
      android_jar="$candidate"
      break
    fi
  done
fi

if [ -z "$d8_jar" ]; then
  for candidate in \
    /opt/homebrew/share/android-commandlinetools/cmdline-tools/latest/lib/r8-classpath.jar \
    /opt/homebrew/share/android-commandlinetools/cmdline-tools/latest/lib/d8-classpath.jar \
    "$android_home/cmdline-tools/latest/lib/r8-classpath.jar" \
    "$android_sdk_root/cmdline-tools/latest/lib/r8-classpath.jar"
  do
    if [ -f "$candidate" ]; then
      d8_jar="$candidate"
      break
    fi
  done
fi

[ -f "$android_jar" ] || {
  echo "ERROR android.jar not found; set ANDROID_JAR" >&2
  exit 1
}
[ -f "$d8_jar" ] || {
  echo "ERROR d8/r8 classpath jar not found; set D8_JAR" >&2
  exit 1
}

rm -rf "$build_dir"
mkdir -p "$classes_dir" "$build_dir/d8"

find "$src_dir" -name '*.java' > "$build_dir/sources.list"
javac -source 8 -target 8 -bootclasspath "$android_jar" -d "$classes_dir" @"$build_dir/sources.list"

(cd "$classes_dir" && jar cf "$build_dir/classes.jar" .)

java -cp "$d8_jar" com.android.tools.r8.D8 \
  --min-api 28 \
  --output "$build_dir/d8" \
  "$build_dir/classes.jar"

cp "$build_dir/d8/classes.dex" "$out_dex"
echo "$out_dex"
