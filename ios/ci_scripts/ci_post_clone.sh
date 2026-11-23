#!/bin/sh
#
# Xcode Cloud runs this right after cloning the repo. The runner has no Flutter SDK and none of the
# gitignored files the build needs (Generated.xcconfig, ios/Flutter/ephemeral Swift packages), so
# they are rebuilt here. Adapted from the showtrack script; no remote Swift packages are used by
# this app, so no Package.resolved needs to be committed.
set -e
set -x

# Must match the dev machine (`flutter --version`): this Flutter uses Swift Package Manager for
# plugins, so the Xcode project references the gitignored ios/Flutter/ephemeral/Packages/.
FLUTTER_VERSION="3.44.6"

cd "$CI_PRIMARY_REPOSITORY_PATH"

# Downloads from Google hosts sometimes reset connections: retry a few times.
retry() {
    attempt=1
    until "$@"; do
        if [ "$attempt" -ge 3 ]; then
            return 1
        fi
        attempt=$((attempt + 1))
        sleep 20
    done
}

git clone https://github.com/flutter/flutter.git --depth 1 -b "$FLUTTER_VERSION" "$HOME/flutter"
export PATH="$PATH:$HOME/flutter/bin"
retry flutter --version
retry flutter precache --ios

# Version name from pubspec.yaml unless started by a tag (v1.2.0 -> 1.2.0); build number from
# Xcode Cloud's increasing counter (TestFlight needs a unique, increasing build number).
VERSION_NAME=$(sed -nE 's/^version: ([^+]+).*/\1/p' pubspec.yaml)
case "$CI_TAG" in
    v[0-9]*.[0-9]*.[0-9]*) VERSION_NAME="${CI_TAG#v}" ;;
esac
sed -i '' -E "s/^version: .*/version: ${VERSION_NAME}+${CI_BUILD_NUMBER}/" pubspec.yaml
grep '^version:' pubspec.yaml

retry flutter pub get
# Generates ios/Flutter/ephemeral (plugin Swift packages) and Generated.xcconfig.
retry flutter build ios --config-only --release --no-codesign

echo "ci_post_clone.sh: done"
