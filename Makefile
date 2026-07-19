.PHONY: setup dev build-app test test-benchmark format format-check verify release

setup:
	cd apps/macos && swift package resolve

dev:
	./scripts/dev.sh

build-app:
	./scripts/build-macos-app.sh release

test:
	zsh ./scripts/verify-repository.sh app-tests

test-benchmark:
	zsh ./scripts/verify-repository.sh benchmark-tests

format:
	xcrun swift-format format --in-place --recursive --configuration .swift-format apps/macos/Sources apps/macos/Tests benchmarks/swift-tts/Sources benchmarks/swift-tts/Tests

format-check:
	zsh ./scripts/verify-repository.sh static

verify:
	zsh ./scripts/verify-repository.sh

release:
	bundle exec fastlane mac release
