PROTO_SOURCE=./protocol/protobufs

NANOPB_VENV=.build/nanopb-venv
NANOPB_GEN=$(NANOPB_VENV)/bin/nanopb_generator
PROTO_STAGE=.build/proto-stage
PROTOC_INCLUDE=$(shell brew --prefix)/include
CLIENT_PROTOS=livekit_models livekit_rtc livekit_metrics

# Regenerates the whole protocol layer:
#   1. SwiftProtobuf "oracle" (test-only): naming source for the facade
#      generator and the conformance tests' independent implementation.
#   2. nanopb C descriptors/structs — the actual wire format. Every field is
#      FT_POINTER (one generated options line per proto): code size is
#      identical to selective pointers, no field can silently degrade to a
#      nanopb callback, and new proto fields need no options maintenance.
#      Cost is one malloc per set scalar field — noise at signalling rates.
#   3. scripts/generate-facades.swift — descriptor-driven (FileDescriptorSet +
#      SwiftProtobufPluginLibrary's namer, no C-header or generated-Swift
#      parsing); fails loudly if a new proto field would silently become a
#      nanopb callback, or if any emitted setter skips the CoW guard.
proto: protoc protoc-swift swift-sh nanopb-generator
	protoc --swift_out=Tests/LiveKitNanopbTests/Oracle -I=${PROTO_SOURCE} \
		$(foreach p,$(CLIENT_PROTOS),${PROTO_SOURCE}/$(p).proto)
	rm -rf $(PROTO_STAGE)
	mkdir -p $(PROTO_STAGE)/google/protobuf $(PROTO_STAGE)/logger
	cp $(foreach p,$(CLIENT_PROTOS),${PROTO_SOURCE}/$(p).proto) $(PROTO_STAGE)/
	for p in $(CLIENT_PROTOS) google/protobuf/timestamp logger/options; do \
		echo '* type:FT_POINTER' > $(PROTO_STAGE)/$$p.options; \
	done
	cp ${PROTO_SOURCE}/logger/options.proto $(PROTO_STAGE)/logger/
	cp $(PROTOC_INCLUDE)/google/protobuf/timestamp.proto $(PROTO_STAGE)/google/protobuf/
	mkdir -p $(PROTO_STAGE)/out
	protoc -I=$(PROTO_STAGE) --include_imports \
		--descriptor_set_out=$(PROTO_STAGE)/descriptors.pb \
		$(foreach p,$(CLIENT_PROTOS),$(PROTO_STAGE)/$(p).proto) \
		$(PROTO_STAGE)/google/protobuf/timestamp.proto
	@# --strip-path flattens #include directives; headers are copied flat below.
	@# CocoaPods flattens all pod headers into one directory, so nested
	@# includes ("google/protobuf/timestamp.pb.h") would break pod builds.
	$(NANOPB_GEN) -I $(PROTO_STAGE) -D $(PROTO_STAGE)/out --strip-path \
		--error-on-unmatched \
		$(foreach p,$(CLIENT_PROTOS),$(PROTO_STAGE)/$(p).proto) \
		$(PROTO_STAGE)/google/protobuf/timestamp.proto \
		$(PROTO_STAGE)/logger/options.proto
	cp $(PROTO_STAGE)/out/livekit_*.pb.h Sources/CLiveKitProto/include/
	cp $(PROTO_STAGE)/out/livekit_*.pb.c Sources/CLiveKitProto/
	@# --strip-path only flattens each file's include of its own header;
	@# cross-file includes keep the proto import path and need flattening here.
	sed -i '' \
		-e 's|#include "google/protobuf/timestamp.pb.h"|#include "timestamp.pb.h"|' \
		-e 's|#include "logger/options.pb.h"|#include "options.pb.h"|' \
		Sources/CLiveKitProto/include/livekit_*.pb.h
	cp $(PROTO_STAGE)/out/google/protobuf/timestamp.pb.h Sources/CLiveKitProto/include/
	cp $(PROTO_STAGE)/out/google/protobuf/timestamp.pb.c Sources/CLiveKitProto/
	@# logger/options.proto declares only annotations — header needed, no .c
	cp $(PROTO_STAGE)/out/logger/options.pb.h Sources/CLiveKitProto/include/
	swift-sh scripts/generate-facades.swift

nanopb-generator:
ifeq (, $(wildcard $(NANOPB_GEN)))
	python3 -m venv $(NANOPB_VENV)
	$(NANOPB_VENV)/bin/pip -q install 'nanopb==0.4.9.1'
endif

swift-sh:
ifeq (, $(shell which swift-sh))
	brew install swift-sh
endif

docs: swift-docs
	swift doc generate Sources/LiveKit \
		--module-name "LiveKit Swift Client SDK" \
		--output Documentation \
		--format html \
		--base-url /client-sdk-swift

protoc-swift:
ifeq (, $(shell which protoc-gen-swift))
	brew install swift-protobuf
endif

protoc:
ifeq (, $(shell which protoc))
	brew install protobuf
endif

swift-docs:
ifeq (, $(shell which swift-doc))
	brew install swiftdocorg/formulae/swift-doc
endif
