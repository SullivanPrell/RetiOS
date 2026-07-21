#!/bin/sh
#
# Rebuild Yggdrasil.xcframework (the gomobile-bound yggdrasil-go engine that the
# YggdrasilTunnel network extension runs) and vendor it into RetiOS/Frameworks/.
#
# Requirements:
#   - Go 1.25+            (yggdrasil-go go.mod declares `go 1.25.0`)
#   - gomobile + gobind   go install golang.org/x/mobile/cmd/gomobile@latest
#                         go install golang.org/x/mobile/cmd/gobind@latest
#   - Xcode command-line tools (for the iOS/macOS SDKs)
#
# The engine source lives in the repo at:
#   reference_implementations/yggdrasil-go   (yggdrasil-go v0.5.14)
#
# We bind the STANDARD mobile API (contrib/mobile: MobileYggdrasil with
# StartJSON / GetAddressString / GetSubnetString / GetMTU / TakeOverTUN / Stop /
# GetPeersJSON, plus the free MobileGenerateConfigJSON / MobileGetVersion). This
# is exactly the surface the reference yggdrasil-ios app (and our extension) use.
#
set -ef

HERE=$(cd "$(dirname "$0")/.." && pwd)                    # .../swift_devel/RetiOS
YGG_SRC=$(cd "$HERE/../../reference_implementations/yggdrasil-go" && pwd)
DEST="$HERE/Frameworks/Yggdrasil.xcframework"

export PATH="$PATH:$(go env GOPATH)/bin"

cd "$YGG_SRC"
PKGSRC=github.com/yggdrasil-network/yggdrasil-go/src/version
PKGVER=$(git describe --tags 2>/dev/null || echo "v0.5.14")
LDFLAGS="-X $PKGSRC.buildName=yggdrasil -X $PKGSRC.buildVersion=$PKGVER -s -w"

echo "Building Yggdrasil.xcframework ($PKGVER) — ios + iossimulator + macos ..."
rm -rf Yggdrasil.xcframework
gomobile bind \
  -target ios,iossimulator,macos -tags mobile \
  -o Yggdrasil.xcframework \
  -ldflags="$LDFLAGS" \
  ./contrib/mobile ./src/config

echo "Vendoring into $DEST"
rm -rf "$DEST"
mkdir -p "$HERE/Frameworks"
cp -R Yggdrasil.xcframework "$DEST"
rm -rf Yggdrasil.xcframework

echo "Done. Slices:"
find "$DEST" -maxdepth 1 -type d ! -path "$DEST"
