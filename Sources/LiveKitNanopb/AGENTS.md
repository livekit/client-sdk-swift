# LiveKitNanopb

Swift runtime for the nanopb-backed protobuf facades in `Sources/LiveKit/Protos`.
Generated C lives in `Sources/CLiveKitProto`; the generator is
`scripts/generate-swift-protos.swift` (run via `make proto`). See the *Protocol
Layer* section of the root `AGENTS.md` for the update/validation workflow.

## Why this exists

SwiftProtobuf links a ~1.1 MB runtime plus heavy per-message generated code
regardless of how little of it the SDK uses. nanopb keeps the wire format in
compact C field tables, and this target is a fixed-cost (~700 line) bridge that
does not grow with the number of messages. The migration cut the SDK's
download-size contribution by ~1.7 MB. A stripped fork of SwiftProtobuf was
evaluated and bottoms out ~2.3× larger (see PR #1081 discussion) — the overhead
is structural (per-message metadata, codec logic), not trimmable.

The facades keep protoc-gen-swift's shape where it costs nothing (`Livekit_Room`,
`.with {}`, `serializedBytes()`, `Equatable`/`Hashable`/`Sendable` value types),
so most SDK call sites are unchanged, and `Tests/LiveKitNanopbTests` can assert
byte-identical encoding against SwiftProtobuf as an independent oracle. Three
deliberate departures: **messages are immutable** (`msg.field = x` does not
compile — build with `.with { }`, derive with `.modifying { }`), **nested type
names are flat** (`Livekit_DataPacket_Kind`), and **enums are open**
(`RawRepresentable` structs, so a `switch` needs a `default`).

## Design

Three layers:

1. **`CLiveKitProto`** — vendored nanopb 0.4.9.1 runtime + generated C structs
   and field descriptors. All fields use `FT_POINTER` (heap-allocated), so
   structs are small and `pb_release` frees everything. ABI defines and the
   `pb_*` → `lk_pb_*` symbol renames live in `lk_pb_config.h` /
   `lk_pb_rename.h` (see those headers for the Firebase-collision and
   SwiftPM-importer rationale).
2. **`LiveKitNanopb`** (this target) — `NanopbBox` ownership, the generic
   `NanopbMsg<Storage>` (wire format, equality, `with` / `modifying` /
   `owned()`), the `NanopbStorage` protocol each C struct conforms to, and the
   `lk*` field accessors the generated code calls.
3. **Generated facades** — for each message the SDK references (type-level
   pruning): a one-line `NanopbStorage` conformance on the imported C struct,
   a typealias, and the field accessors. No Swift *type* per message.

   ```swift
   extension livekit_Room: NanopbStorage {
       package static var descriptor: pb_msgdesc_t { livekit_Room_msg }
       package static let _emptyBox = NanopbBox<livekit_Room>(zero: .init(), descriptor: livekit_Room_msg)
   }
   typealias Livekit_Room = NanopbMsg<livekit_Room>
   extension Livekit_Room { /* getters */ }
   extension Livekit_Room.Builder { /* setters */ }
   ```

   **Why one generic type is the whole point.** A nominal Swift type's metadata
   and conformance records live in sections the runtime must be able to
   enumerate, so the linker keeps them even when nothing references the type —
   measured on a dead-stripped link with a single exported symbol, message types
   the workload never touched still carried 79–205 live symbols each. Accessor
   *code* strips; types do not. Collapsing 107 nominal types into one took the
   facades from 214,686 to 89,627 bytes.

   Extending through the typealias (`extension Livekit_Room`) is exactly
   `extension NanopbMsg where S == livekit_Room`; Swift resolves a typealias
   that binds a generic's parameters. Prefer the typealias form — it keeps the
   C struct name out of everything but the conformance.

   Three constraints the shape has to respect:

   - `NanopbBuilder._pointer` is *stored*: as a computed property off `_box` it
     crashes the Swift 6.1 SIL verifier, and 6.1 is the floor.
   - **Nested types are flattened** to file scope (`Livekit_DataPacket_Kind`),
     because constrained extensions of one generic cannot each declare a member
     of the same name — six `OneOf_Value` declarations would collide. A message
     that carries *only* nested types is emitted as a caseless enum namespace
     instead of a typealias, which keeps `Livekit_DataStream.Header` compiling.
   - `_empty` lives on the storage conformance as `_emptyBox`, because Swift
     forbids stored statics in a generic type and a computed `Self()` would
     allocate on every read of an absent submessage.

A message value is `NanopbMsg<Storage>`, holding `_owner: NanopbAnyBox`
(lifetime) and `_pointer` (a nanopb C struct in a malloc'd, address-stable
allocation). It is in one of two states:

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
  Call `owned()` when promoting a sub-message into long-lived state (the
  SDK does this for `Participant.info`, `latestInfo`, `serverInfo`). Owning
  values pass through `owned()` unchanged. Immutability does not remove this
  hazard: a view is still a pointer into a bigger allocation.
- **Copying is free**: assigning a message bumps the box refcount and can
  never deep-copy, because a message has no setters — there is no later
  mutation for a copy to defend against. Building goes through `Builder`,
  which allocates its own box, so it needs no uniqueness check either.
- **Deriving from an existing message**: `modifying { }` is `consuming`. When
  the caller's value was the last owner the mutation happens in place; when it
  is shared (or is a view) it copies once for the whole batch, never per field.
  Marking a parameter `consuming` on the way in is what lets the in-place path
  fire — see `Room.send(dataPacket:)`.
- **Deep copy = encode/decode round trip**: nanopb has no clone; a struct's
  pointers cannot be shared between two trees that will both be released. The
  round trip is the correctness-safe copy and doubles as tested code. Two
  consequences: copies are O(subtree size), and **unknown fields are dropped**
  on copy/re-encode (pinned in `ConformanceEdgeCaseTests` — acceptable because
  the SDK never echoes messages back verbatim).
- **Crossing the C boundary copies**: setting a submessage on a builder
  (`$0.version = v`) encodes `v` into the builder's allocation; getting one
  hands out a view. There is no aliasing between two Swift values' storage
  except the read-only box/view sharing above. Nested mutation
  (`$0.a.b = c`) does not compile — write `$0.a = .with { $0.b = c }`.
- **Oneofs**: union members share an address, so switching variants releases
  the old payload with the *old* variant's descriptor before writing the new
  one (`lkRelease`), then zeroes the union. Getters for non-active variants
  return empty values.
- **Presence**: `FT_POINTER` means presence *is* the pointer — an explicitly
  set zero scalar is allocated and therefore encoded (a deliberate,
  oracle-pinned difference from SwiftProtobuf; harmless to consumers).

## Concurrency semantics

`NanopbBox` is `@unchecked Sendable`; messages are `Sendable` value types. The
justification is immutability, and the compiler enforces most of it:

- Storage a message can reach is **never mutated**. A message has no setters;
  the only writer is a `Builder`, and `Builder` is `~Copyable` and consumed by
  `build()`, so no live handle can write to storage after it is published.
- Concurrent **reads** of shared storage are therefore always safe, including
  reads through views into a shared parent.
- `modifying` writes in place only after `isKnownUniquelyReferenced` proves no
  other value — copy or view — can observe the storage.
- Nothing in this target adds locks; safety comes from the type system, not
  synchronization.

`Tests/LiveKitNanopbTests/ConcurrencyStressTests` exercises the claim under
TSan (shared reads, concurrent `modifying` on copies, view lifetime, view
stability during sibling mutation, oneof churn, collection churn); CI's TSan
matrix leg runs it on every push. When touching `modifying`, `owned()`, view
construction, or any accessor's free/alloc ordering, run:

```zsh
swift test --filter 'Nanopb|Conformance|ConcurrencyStress' --sanitize=thread
```

## Memory safety

The unsafe surface is the C boundary: `NanopbBox`'s allocation, the `lk*`
accessors, and the pointer reads in the generated facades. Nothing unsafe is
reachable from public API — every declaration here is `package`, and no public
type exposes a pointer.

Each site that carries an invariant the code cannot show for itself has a
`// SAFETY:` comment, the convention Apple's TrueType-hinting port uses
(`apple/truetype-hinting-interpreter-example`). Add one when introducing a new
unsafe operation; state the invariant, not what the line does.

Swift 6.2's strict memory safety (`.strictMemorySafety()`, `unsafe` expression
markers, `@safe`) is **not** adopted: the markers are 6.2 syntax, a 6.1
compiler rejects them, and they cannot be `#if`-guarded per expression, so
adopting them means moving the floor off Swift 6.1. Compiling this target with
`-strict-memory-safety` today reports ~11,200 warnings, ~5,400 of them in
generated code (the generator would have to emit the markers). Revisit when the
minimum toolchain reaches 6.2.

Already adopted from that port, within the 6.1 floor: typed throws on the wire
API and the scoped borrows (a non-throwing body specialises to `throws(Never)`,
so it needs no `try` and emits no error path), and a shared `_empty` per
message instead of allocating a throwaway value for an absent submessage —
their zone-sentinel trick, sound here only because messages are immutable.

Reachable improvements once the floor moves:

- `Span`/`RawSpan` borrows already exist behind `#if compiler(>=6.2)`
  (`withLkSpan`); they hand the closure a bounds-checked view instead of a raw
  pointer, and back-deploy to iOS 12.2, so only the compiler gates them.
  Nothing calls them yet — they are kept as the proven shape for the first hot
  path that needs one, not as an API to reach for by default.
- Making views `~Escapable` with `@_lifetime` would turn "stored a view and
  pinned the parent allocation" from a memory-growth bug into a compile error.
  Apple's port does exactly this for its `Zone` projection, but it needs
  `.enableExperimentalFeature("Lifetimes")`.

## Tradeoffs (deliberate)

- **Enums are `RawRepresentable` structs, not Swift enums**: proto3 enums are
  open, so an unknown wire value is an ordinary value rather than a special
  case. That removes the `UNRECOGNIZED(Int)` payload and the switch-based
  `rawValue` / `init?(rawValue:)` pair (~660 lines), and makes the failable
  init honest — it never could fail. The cost is that a `switch` over one needs
  a `default`, which an open enum always required semantically. `CaseIterable`
  is not emitted; nothing used `allCases`.

- **Equality/hashing via canonical bytes**: nanopb encodes deterministically
  except map *entry order* is preserved, so equal maps built in different
  orders compare unequal. The SDK uses equality for change detection, where a
  false "changed" is benign. Don't use facade equality where map-order
  insensitivity matters.
- **No crashing in the runtime**: encode/decode failures on paths that cannot
  throw (builder setters, the `modifying` copy) are reported via
  `nanopbReportFailure` (os_log `.fault`, subsystem `io.livekit.nanopb`) and
  degrade to the least-damaging outcome — a setter leaves the destination
  unchanged, a failed copy yields an *empty* value rather than aliasing
  storage. These only fire on allocation exhaustion or a descriptor bug.
- **Collections materialize**: repeated/map getters build Swift arrays and
  dictionaries of (for submessages) views. Submessage and repeated-submessage
  reads stay zero-copy — the elements are views — but scalar, string and bytes
  reads copy out.

  There is deliberately **no** per-field borrow accessor. The generator used to
  emit one for every string and bytes field, 128 of them, and not a single call
  site ever used one; the receive path hands consumers a `Data` anyway, so the
  copy happens at the API boundary regardless. `withLkData` / `withLkRepeated`
  remain as runtime primitives if a real hot path ever needs one, and the
  generator can re-emit wrappers on demand the same way it prunes types.
- **`package` access everywhere**: this target is SDK plumbing, never public
  API. In single-module builds (CocoaPods, xcframework) these sources compile
  into the product directly — see the `#if LK_XCFRAMEWORK / #elseif !COCOAPODS`
  import guards at the top of each file, and keep them on any new file.

## Invariants to preserve when editing

1. Setters exist only on `Builder`, never on a message — the generator's
   `verifyBuilderInvariant` fails the build otherwise. It keys on the emitted
   `extension <Type>.Builder {` header, so keep that spelling.
2. Every `free`/`lk_pb_release` matches the allocation's actual layout —
   especially oneof switches (release with the old variant's descriptor).
3. New runtime symbols from a nanopb upgrade must be added to
   `lk_pb_rename.h` (`nm -gU` the runtime objects to enumerate).
4. No new synchronization primitives; safety is immutability.
5. Conformance suites must stay green — they are the encoding oracle:
   `swift test --filter 'Nanopb|Conformance'`.
6. `Livekit_DataPacket` is decoded from bytes another participant sent, so the
   decoder is the SDK's only parser facing untrusted input. `DecodeFuzzTests`
   walks mutated and random encodings through it from a fixed seed; run it
   under ASan (`--sanitize=address`) after touching decode or any accessor's
   pointer arithmetic, since an out-of-bounds read there need not crash.
