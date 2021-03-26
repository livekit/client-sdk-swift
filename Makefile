PROTO_SOURCE=../protocol

proto: protoc protoc-swift
	protoc --swift_out=Sources/LiveKit/proto -I=${PROTO_SOURCE} ${PROTO_SOURCE}/livekit_models.proto ${PROTO_SOURCE}/livekit_rtc.proto

protoc-swift:
ifeq (, $(shell which protoc-gen-swift))
	brew install swift-protobuf
endif

protoc:
ifeq (, $(shell which protoc))
	brew install protobuf
endif
