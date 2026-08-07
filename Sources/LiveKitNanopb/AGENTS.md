# LiveKitNanopb

Swift runtime for the nanopb-backed protobuf facades in `Sources/LiveKit/Protos`.
Generated C lives in `Sources/CLiveKitProto`; the generator is
`scripts/generate-swift-protos.swift` (run via `make proto`).

**Everything about this layer — why it exists, the design and the constraints
it has to respect, memory and concurrency semantics, memory safety, deliberate
tradeoffs, and the invariants to preserve when editing — lives in
[PROTOCOL.md](../../PROTOCOL.md) at the repo root.** Keep it there rather than
here, so there is one copy to update.
