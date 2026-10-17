#!/bin/bash
# Sign an app bundle inside-out with one identity.
#
# Usage: sign-app.sh <app> <identity> <entitlements>
#
# TCC keys privacy grants (Accessibility, Camera, Calendar, Location, Apple
# Events) to the signature's designated requirement. An ad-hoc identity ("-")
# pins that requirement to the cdhash, so every rebuild looks like a new app
# and the user is asked to authorize again. A certificate identity pins it to
# the certificate, so grants survive rebuilds and updates as long as the same
# certificate keeps signing.
set -euo pipefail

APP="$1"
IDENTITY="$2"
ENTITLEMENTS="$3"

if [ "$IDENTITY" = "-" ]; then
    echo 'warning: ad-hoc signing; privacy permissions will be requested again after every rebuild.' >&2
    echo 'Set SIGN_IDENTITY to a code-signing certificate to keep them (see ReadMe, Local Signing).' >&2
fi

# Sign nested executables and bundles before sealing the outer application.
while IFS= read -r -d '' item; do
    if /usr/bin/file -b "$item" | /usr/bin/grep -q 'Mach-O'; then
        codesign --force --sign "$IDENTITY" --timestamp=none "$item"
    fi
done < <(find "$APP" -type f -print0)

while IFS= read -r -d '' item; do
    if [ "$item" != "$APP" ]; then
        codesign --force --sign "$IDENTITY" --timestamp=none "$item"
    fi
done < <(find "$APP" -depth \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.app' \) -type d -print0)

codesign --force --sign "$IDENTITY" --timestamp=none --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"
codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /Designated requirement: /p'
