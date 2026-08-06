.PHONY: build run clean install package

build:
	swift build

run:
	swift run

clean:
	rm -rf .build

install: package
	ditto .build/KimiQuotaBar.app /Applications/KimiQuotaBar.app

package: build
	@echo "Packaging KimiQuotaBar.app..."
	@rm -rf .build/KimiQuotaBar.app
	@mkdir -p .build/KimiQuotaBar.app/Contents/MacOS
	@mkdir -p .build/KimiQuotaBar.app/Contents/Resources
	@cp .build/debug/KimiQuotaBar .build/KimiQuotaBar.app/Contents/MacOS/
	@/usr/libexec/PlistBuddy -c "Clear dict" \
		-c "Add :CFBundleExecutable string KimiQuotaBar" \
		-c "Add :CFBundleIdentifier string com.ijkzen.KimiQuotaBar" \
		-c "Add :CFBundleName string KimiQuotaBar" \
		-c "Add :CFBundlePackageType string APPL" \
		-c "Add :CFBundleShortVersionString string 1.0" \
		-c "Add :CFBundleIconFile string AppIcon" \
		-c "Add :LSUIElement bool true" \
		-c "Add :NSLocalNetworkUsageDescription string 需要访问局域网内的 CookieCloud 服务器以同步 OpenCode Go 登录状态" \
		.build/KimiQuotaBar.app/Contents/Info.plist >/dev/null
	@rm -rf .build/AppIcon.iconset
	@mkdir -p .build/AppIcon.iconset
	@sips -z 16 16 assets/AppIcon.png --out .build/AppIcon.iconset/icon_16x16.png >/dev/null
	@sips -z 32 32 assets/AppIcon.png --out .build/AppIcon.iconset/icon_16x16@2x.png >/dev/null
	@sips -z 32 32 assets/AppIcon.png --out .build/AppIcon.iconset/icon_32x32.png >/dev/null
	@sips -z 64 64 assets/AppIcon.png --out .build/AppIcon.iconset/icon_32x32@2x.png >/dev/null
	@sips -z 128 128 assets/AppIcon.png --out .build/AppIcon.iconset/icon_128x128.png >/dev/null
	@sips -z 256 256 assets/AppIcon.png --out .build/AppIcon.iconset/icon_128x128@2x.png >/dev/null
	@sips -z 256 256 assets/AppIcon.png --out .build/AppIcon.iconset/icon_256x256.png >/dev/null
	@sips -z 512 512 assets/AppIcon.png --out .build/AppIcon.iconset/icon_256x256@2x.png >/dev/null
	@sips -z 512 512 assets/AppIcon.png --out .build/AppIcon.iconset/icon_512x512.png >/dev/null
	@sips -z 1024 1024 assets/AppIcon.png --out .build/AppIcon.iconset/icon_512x512@2x.png >/dev/null
	@iconutil -c icns -o .build/KimiQuotaBar.app/Contents/Resources/AppIcon.icns .build/AppIcon.iconset >/dev/null
	@rm -rf .build/AppIcon.iconset
	@codesign --force --deep --sign - .build/KimiQuotaBar.app >/dev/null 2>&1 || true
	@echo "Created .build/KimiQuotaBar.app"
