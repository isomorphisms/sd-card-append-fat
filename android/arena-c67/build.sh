#!/bin/sh
set -eu

repo=$(git rev-parse --show-toplevel)
app="$repo/android/arena-c67"
sdk="$ANDROID_SDK_ROOT"
abi=${ANDROID_ABI:-arm64-v8a}
platform_api=34
build_tools=35.0.0
ndk_version=27.2.12479018
build="$app/build-$abi"

case "$abi" in
    arm64-v8a)
        triple=aarch64-linux-android26
        ;;
    armeabi-v7a)
        triple=armv7a-linux-androideabi26
        ;;
    *)
        printf '%s\n' "unsupported ANDROID_ABI: $abi" >&2
        exit 2
        ;;
esac

rm -rf "$build"
mkdir -p "$build/ziproot/lib/$abi"

if [ -x "$sdk/cmdline-tools/latest/bin/sdkmanager" ]; then
    sdkmanager_cmd="$sdk/cmdline-tools/latest/bin/sdkmanager"
elif [ -x "$sdk/tools/bin/sdkmanager" ]; then
    sdkmanager_cmd="$sdk/tools/bin/sdkmanager"
else
    sdkmanager_cmd=$(find "$sdk/cmdline-tools" -type f -name sdkmanager 2>/dev/null | head -1)
fi
[ -n "$sdkmanager_cmd" ] || {
    printf '%s\n' 'sdkmanager not found under ANDROID_SDK_ROOT' >&2
    exit 1
}
"$sdkmanager_cmd" "platforms;android-34" "build-tools;35.0.0" "ndk;27.2.12479018" >/dev/null

platform="$sdk/platforms/android-$platform_api/android.jar"
bt="$sdk/build-tools/$build_tools"
ndk="$sdk/ndk/$ndk_version"
cc="$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/$triple-clang"

"$cc" -std=c11 -O2 -fPIC -shared -Wall -Wextra -Werror \
    -I"$repo/lib" \
    -DTARGET_ABI="\"$abi\"" \
    "$repo/lib/appendfat_arena.c" \
    "$app/jni/arena_app.c" \
    -o "$build/ziproot/lib/$abi/libappendfat_arena_app.so" \
    -landroid -llog

"$bt/aapt2" link \
    -I "$platform" \
    --manifest "$app/AndroidManifest.xml" \
    -o "$build/base.apk"

cp "$build/base.apk" "$build/unsigned.apk"
(
    cd "$build/ziproot"
    zip -q -r "$build/unsigned.apk" lib
)
"$bt/zipalign" -f -p 4 "$build/unsigned.apk" "$build/aligned.apk"

keytool -genkeypair -noprompt \
    -keystore "$build/arena-test.jks" \
    -storepass android -keypass android \
    -alias appendfat-arena-test \
    -dname "CN=appendFAT Arena Qualification,O=isomorphisms" \
    -keyalg RSA -keysize 2048 -validity 3650 >/dev/null 2>&1

apk="$build/appendfat-arena-$abi.apk"
"$bt/apksigner" sign \
    --ks "$build/arena-test.jks" \
    --ks-pass pass:android \
    --key-pass pass:android \
    --out "$apk" \
    "$build/aligned.apk"

"$bt/apksigner" verify --verbose "$apk"
{
    printf 'source_sha=%s\n' "$(git rev-parse HEAD)"
    printf 'package=org.isomorphisms.appendfat.arena\n'
    printf 'abi=%s\n' "$abi"
    printf 'min_sdk=26\n'
    printf 'target_sdk=34\n'
    sha256sum "$apk"
    "$bt/apksigner" verify --print-certs "$apk"
    "$bt/aapt2" dump badging "$apk" |
        grep -E '^(package:|native-code:|sdkVersion:|targetSdkVersion:)'
} | tee "$build/receipt.txt"
