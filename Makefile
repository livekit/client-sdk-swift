PROTO_SOURCE=../protocol

proto: protoc protoc-swift
	protoc --swift_out=Sources/LiveKit/proto -I=${PROTO_SOURCE} ${PROTO_SOURCE}/model.proto ${PROTO_SOURCE}/rtc.proto

protoc-swift:
ifeq (, $(shell which protoc-gen-swift))
	brew install swift-protobuf
endif

protoc:
ifeq (, $(shell which protoc))
	brew install protobuf
endif
