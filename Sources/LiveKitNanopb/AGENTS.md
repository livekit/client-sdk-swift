# LiveKitNanopb

Swift runtime for the nanopb-backed protobuf facades in `Sources/LiveKit/Protos`.
Generated C lives in `Sources/CLiveKitProto`; the generator is
`scripts/generate-swift-protos.swift` (run via `make proto`). See the *Protocol
Layer* section of the root `AGENTS.md` for the update/validation workflow.

## Why this exists

SwiftProtobuf links a ~1.1 MB runtime plus heavy per-message generated code
regardless of how little of it the SDK uses. nanopb keeps the wire format in
compact C field tables, and this target is a fixed-cost (~600 line) bridge that
does not grow with the number of messages. The migration cut the SDK's
download-size contribution by ~1.7 MB. A stripped fork of SwiftProtobuf was
evaluated and bottoms out ~2.3× larger (see PR #1081 discussion) — the overhead
is structural (per-message metadata, codec logic), not trimmable.

The facades clone protoc-gen-swift's API (`Livekit_Room`, `.with {}`,
`serializedBytes()`, `Equatable`/`Hashable`/`Sendable` value types) so SDK call
sites did not change, and `Tests/LiveKitNanopbTests` can assert byte-identical
encoding against SwiftProtobuf as an independent oracle.

## Design

Three layers:

1. **`CLiveKitProto`** — vendored nanopb 0.4.9.1 runtime + generated C structs
   and field descriptors. All fields use `FT_POINTER` (heap-allocated), so
   structs are small and `pb_release` frees everything. ABI defines and the
   `pb_*` → `lk_pb_*` symbol renames live in `lk_pb_config.h` /
   `lk_pb_rename.h` (see those headers for the Firebase-collision and
   SwiftPM-importer rationale).
2. **`LiveKitNanopb`** (this target) — `NanopbBox` ownership, the
   `NanopbMessage` protocol (CoW, wire format, equality), and the `lk*` field
   accessors the generated code calls.
3. **Generated facades** — one Swift struct per message the SDK references
   (type-level pruning), with computed properties over the C struct.

A message value is a `struct` holding `_owner: AnyObject` (lifetime) and
`_pointer` (a nanopb C struct in a malloc'd, address-stable allocation). It is
in one of two states:

- **Owning**: `_owner` is its own `NanopbBox`; `box.pointer == _pointer`.
- **View**: `_pointer` aims at a nested C struct *inside another message's
  allocation*, and `_owner` is that parent's box. Submessage and repeated
  getters return views — reads are zero-copy pointer reads.

## Memory semantics

- **Ownership**: `NanopbBox.deinit` runs `lk_pb_release` (frees all dynamic
  fields recursively) then deallocates the struct. Nothing else frees a
  message's tree; accessor setters free only the single field slot they
  replace (`free` old string/bytes/pointer, `strdup`/`malloc` new).
- **Views keep parents alive**: a view retains the parent's box, so extracting
  `response.update.participants[0]` and dropping `response` is safe — but
  storing a view long-term pins the *entire* decoded message's allocation.
  Call `detached()` when promoting a sub-message into long-lived state (the
  SDK does this for `Participant.info`, `latestInfo`, `serverInfo`). Owning
  values pass through `detached()` unchanged.
- **Copy-on-write**: assigning a message copies nothing — it bumps the box
  refcount. The first mutation of a value whose box is shared (a copy, or the
  parent/child of a view) detaches it first: `_ensureUnique()` deep-copies the
  value's own subtree via an encode/decode round trip. Typical SDK traffic is
  build-encode-drop or decode-read-drop, so detaches are rare.
- **Deep copy = encode/decode round trip**: nanopb has no clone; a struct's
  pointers cannot be shared between two trees that will both be released. The
  round trip is the correctness-safe copy and doubles as tested code. Two
  consequences: copies are O(subtree size), and **unknown fields are dropped**
  on copy/re-encode (pinned in `ConformanceEdgeCaseTests` — acceptable because
  the SDK never echoes messages back verbatim).
- **Crossing the C boundary copies**: setting a submessage
  (`room.version = v`) encodes `v` into the parent's allocation; getting one
  hands out a view. There is no aliasing between two Swift values' storage
  except the read-only CoW/view sharing above.
- **Oneofs**: union members share an address, so switching variants releases
  the old payload with the *old* variant's descriptor before writing the new
  one (`lkRelease`), then zeroes the union. Getters for non-active variants
  return empty values.
- **Presence**: `FT_POINTER` means presence *is* the pointer — an explicitly
  set zero scalar is allocated and therefore encoded (a deliberate,
  oracle-pinned difference from SwiftProtobuf; harmless to consumers).

## Concurrency semantics

`NanopbBox` is `@unchecked Sendable`; messages are `Sendable` value types. The
justification is the same invariant as `Array`:

- Storage reachable from more than one value is **never mutated** — every
  generated setter calls `_ensureUnique()` first, which detaches unless
  `isKnownUniquelyReferenced(&_owner)`.
- Concurrent **reads** of shared storage are safe (pointer reads of immutable
  memory). Concurrent mutation of *distinct copies* is safe (each detaches to
  private storage).
- The only contract callers must uphold is Swift's ordinary exclusivity rule:
  don't mutate the *same* `var` from two threads. Nothing in this target adds
  locks — safety comes from the CoW invariant, not synchronization.

`Tests/LiveKitNanopbTests/ConcurrencyStressTests` exercises the claim under
TSan (shared reads, copy detach, view lifetime, view stability during sibling
mutation, oneof churn, collection churn); CI's TSan matrix leg runs it on
every push. When touching `_ensureUnique`, `detached()`, view construction, or
any accessor's free/alloc ordering, run:

```zsh
swift test --filter 'Nanopb|Conformance|ConcurrencyStress' --sanitize=thread
```

## Tradeoffs (deliberate)

- **Equality/hashing via canonical bytes**: nanopb encodes deterministically
  except map *entry order* is preserved, so equal maps built in different
  orders compare unequal. The SDK uses equality for change detection, where a
  false "changed" is benign. Don't use facade equality where map-order
  insensitivity matters.
- **No crashing in the runtime**: encode/decode failures on paths that cannot
  throw (setters, the CoW guard) are reported via `nanopbReportFailure`
  (os_log `.fault`, subsystem `io.livekit.nanopb`) and degrade to the
  least-damaging outcome — a setter leaves the destination unchanged, the CoW
  guard detaches to an *empty* value rather than mutate shared storage. These
  only fire on allocation exhaustion or a descriptor bug.
- **Collections materialize**: repeated/map getters build Swift arrays and
  dictionaries of (for submessages) views. Hot paths should use the zero-copy
  borrows instead: `withEncodedBytes`, `withLkData`, `withLkRepeated`.
- **`package` access everywhere**: this target is SDK plumbing, never public
  API. In single-module builds (CocoaPods, xcframework) these sources compile
  into the product directly — see the `#if LK_XCFRAMEWORK / #elseif !COCOAPODS`
  import guards at the top of each file, and keep them on any new file.

## Invariants to preserve when editing

1. Every mutation path calls `_ensureUnique()` before writing.
2. Every `free`/`lk_pb_release` matches the allocation's actual layout —
   especially oneof switches (release with the old variant's descriptor).
3. New runtime symbols from a nanopb upgrade must be added to
   `lk_pb_rename.h` (`nm -gU` the runtime objects to enumerate).
4. No new synchronization primitives; safety is the CoW invariant.
5. Conformance suites must stay green — they are the encoding oracle:
   `swift test --filter 'Nanopb|Conformance'`.
