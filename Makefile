.PHONY: build

build:
	npm ci
	npm run build
	xcodebuild -project OpenAPIViewer.xcodeproj -scheme OpenAPIViewer -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build build
