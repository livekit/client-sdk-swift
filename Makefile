docs: swift-docs
	swift doc generate Sources/LiveKit \
		--module-name "LiveKit Swift Client SDK" \
		--output Documentation \
		--format html \
		--base-url /client-sdk-swift


swift-docs:
ifeq (, $(shell which swift-doc))
	brew install swiftdocorg/formulae/swift-doc
endif
