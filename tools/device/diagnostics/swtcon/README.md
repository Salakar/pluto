# Stock Xochitl colour-mapper capture

This captures one isolated Content/UI invocation of Xochitl 3.27.1's active
ct33/A/B mapper without treating a racing worker entry as the pre-state. The
static ABI, offsets, and byte ranges it depends on are pinned in the constants
and provenance blocks below and enforced by the capture and validation scripts.

Paths below are written relative to the repository root; run the commands from
there. `/private/tmp/...` paths are scratch examples — use any writable
location.

## Exact artifacts

```text
stock Xochitl SHA-256:
  4646e0aef1cef2b3417889073ad5faba9259ae6b41f68326e75ef9a5c520c322
ARM64 gdbserver staging path:
  build/device-tools/pluto-gdbserver-aarch64
ARM64 gdbserver SHA-256:
  f5154a1d16d577c90d794199a2bacf66954e6306e4b09281fb7ca1ecaa2fe8be
```

The extracted Ubuntu 24.04 gdbserver requires at most glibc 2.38 and
`GLIBCXX_3.4.29`; the attached Move has glibc 2.39 and
`libstdc++.so.6.0.32`. The macOS host's GDB 14.2 advertises AArch64 remote
support. Recheck both hashes immediately before use.

## One controlled cycle

Do this before provisioning or stopping stock Xochitl. Keep the tablet awake,
idle, and on one stable Content/UI screen.

The orchestrator is the only supported production entrypoint. It verifies both
local binaries, identifies exactly one live untraced Xochitl process, stages and
hashes gdbserver, and exposes gdbserver only through a localhost SSH tunnel. It
also records the Xochitl and gdbserver PID/executable/start-time identities,
uses a timeout-derived remote dead-man, and refuses to signal a tracer unless
that complete identity is the gdbserver it launched.

```sh
python3 tools/device/diagnostics/swtcon/capture_xochitl_mapper.py \
  --device root@10.11.99.1 \
  --xochitl /private/tmp/xochitl-3.27.1.0 \
  --gdbserver build/device-tools/pluto-gdbserver-aarch64 \
  --output /private/tmp/xochitl-mapper-capture
```

Wait until GDB itself prints `Waiting for one isolated Content/UI operation`,
then cause exactly one small stock Content or UI repaint. Do not act on the
wrapper's earlier `GDB is starting` message: the breakpoints are not
yet armed at that point.

The checked GDB script arms all three software breakpoints before printing that
marker. The attached Move's kernel/gdbserver cannot discover the architectural
hardware-breakpoint count and accepted only one simultaneous `hbreak`; the
three boundaries must be armed together. `set breakpoint auto-hw off` makes
the breakpoint kind explicit. Their execution order and ownership are fixed:

1. `break *0x009adbd0` selects exactly one eligible mode-2/5 operation and
   dumps the source descriptor, descriptor-sized ct33 input, selected waveform
   descriptor and 0x800-byte delta, A/B descriptor, and A/B pre-state before
   workers are scheduled. The output descriptor is not constructed yet.
2. `break *0x004814a0` auto-continues each matching mapper worker. The first
   hit dumps the finalized 0xb0-byte context and exact 16-byte palette; one or
   two hits must share context, palette, barrier, and output pointer and exactly
   cover the inclusive update rows.
3. `break *0x009ade2c` runs only on the captured scheduling thread after the
   worker counters drain and while its mutex is held. It dumps the constructed
   output descriptor/payload and A/B post-state. `0x009ade34` is unreachable on
   the successful lock path and is never a capture boundary.

The constructed output rectangle must equal the context update rectangle,
with `stride = (right - left + 16) & ~7` and byte length
`2 * (bottom - top + 3) * stride`. The script ignores multi-operation, skipped,
mismatched-ct33, and non-mode-2/5 work. On an accepted operation it detaches and
exits; the orchestrator then independently proves the same Xochitl PID,
executable, SHA-256, and start-time identity is live, resumed, and has
`TracerPid: 0`. It then reads the four bytes at all three virtual addresses
from that exact process and requires them to match the pinned local ELF file
offsets (`0x814a0`, `0x5adbd0`, and `0x5ade2c`) before invoking the validator.
This makes detach without complete software-breakpoint restoration invalid.

Success requires `CAPTURE_COMPLETE ... valid=1 detached=1`, a zero validator
exit, and `"valid": true` in `capture-manifest.json`. The bundle must include
`cap.target.json`, `cap.recovery.json`, `cap.wavedesc.bin`, `cap.gdb.log`, every
raw dump, and the manifest. Required invariants include a 0x800-byte delta
table, 0x38-byte waveform descriptor whose +0x30 pointer selects that delta,
two 0x645240-byte A/B snapshots, a 16-byte exact palette, descriptor-sized
ct33 input plus formula-sized output, and one or two mapper hits that exactly
cover the update rows. Preserve the whole directory unchanged as one evidence
unit.

Do not substitute the raw GDB script or a manual direct attach for production
capture: those diagnostic pieces do not create the required target/recovery
provenance or enforce the tunnel, dead-man, and identity-bound cleanup. If the
orchestrator cannot prove recovery, stop and inspect the tablet; never provision
while Xochitl may still be ptrace-stopped.

## Offline end-to-end self-test

`test/capture_fixture.c` plus `test/capture_fixture.ld` build a freestanding
ARM64 ELF with synthetic functions at the exact `0x009adbd0`, `0x004814a0`,
and `0x009ade2c` Xochitl breakpoint addresses and an A/B descriptor at
`0x01a18fd8`. Its first operation is mode 3 and must be skipped; its second is
isolated mode 2 and must be captured. Each operation invokes two workers over
contiguous row ranges, so the accepted run also proves the shared
palette/barrier/output contract. The fixture mutates two A/B bytes so the
pre/post dumps also prove boundary order.

The rev10 software-breakpoint self-test on 2026-07-11 rebuilt the fixture
byte-for-byte with pinned local ARM64 toolchain image
`sha256:4f2536450aa0594724ccd2891ffee8eac3b37f4d8267eaadf4a950f65c170952`,
then used the same extracted gdbserver through stdio in a network-disabled,
read-only, capability-dropped ARM64 Ubuntu container and host GDB 14.2. The
exact fixture SHA-256 remained
`657599932efe76a504327c5b1e0f0e3d7c2ed9215ce8176905ed0c1251b6e7e1`.
The log named ordinary `Breakpoint 1..3`, not hardware-assisted stops, and
produced, in order:

```text
CAPTURE_SKIP ... mode=3
CAPTURE_START ... mode=2 ct33_bytes=0x40 ... ab_bytes=0x645240
MAPPER_HIT 1 ... rows=0..3
MAPPER_HIT 2 ... rows=4..7
CAPTURE_COMPLETE ... mapper_hits=2 out_bytes=0x140 ... valid=1 detached=1
```

GDB detached cleanly and gdbserver exited zero. Exact dump sizes were context
176, descriptors 48 each, waveform descriptor 56, ct33 64, output 320, delta
2048, palette 16, and both A/B snapshots 6,574,656 bytes. `cmp -l` found only
the two intentional A/B changes (`2 -> 4` and `6 -> 12`). The validated
manifest had no errors; `cap.gdb.log` SHA-256 was
`09829ae46f2117621d954f6ea4108aeb2d1a8bc7f21821600d8e05e0e5a67dbc`.
This proves software-breakpoint script control flow, remote protocol,
rejection, atomic dump ordering, output validation, and detach; it does not
replace the required stock-device golden or the live instruction-restoration
proof.

`validate_xochitl_capture.py` performs the production gate: it checks the
exact Xochitl hash, fixed and descriptor-derived lengths, context pointers,
mode/temperature, duplicate stride, rects, contiguous worker-row coverage,
mapper context/hit count, nonzero output, and a nonempty A/B transition. With
`--write-manifest` it records all SHA-256 values and parsed metadata. The valid
synthetic bundle passed. Production schema 2 additionally requires the exact
software-breakpoint addresses/file offsets/original bytes and all three live
post-detach instruction words. Corrupt detached proof, waveform delta pointer,
palette, output descriptor, duplicated context stride, injected cleanup error,
and production provenance each failed closed with exit status 1; omitting both
`--fixture` and `--xochitl` failed argument parsing with exit status 2.

## Offline firmware filesystem extraction

`extract_firmware_rootfs.py` reads an extent-based ext4/verity image directly;
it does not mount the image or require root. The source is opened read-only,
all extent and filesystem ranges are checked, special files are skipped, and
tree extraction is confined to a new directory below `/private/tmp`.

```sh
IMAGE=/private/tmp/rm-fw-3.27.1.0/remarkable-production-image-3.27.1.0-chiappa-public.ext4.verity
TOOL=tools/device/diagnostics/swtcon/extract_firmware_rootfs.py

python3 "$TOOL" "$IMAGE" info
python3 "$TOOL" "$IMAGE" list /usr/lib
python3 "$TOOL" "$IMAGE" hash /usr/bin/xochitl
python3 "$TOOL" "$IMAGE" self-test \
  --require /usr/bin/xochitl \
  --require /usr/lib/ld-linux-aarch64.so.1 \
  --expect-sha256 /usr/bin/xochitl=4646e0aef1cef2b3417889073ad5faba9259ae6b41f68326e75ef9a5c520c322
python3 "$TOOL" "$IMAGE" extract /usr/lib \
  --output /private/tmp/rm-fw-3.27.1.0-usr-lib
```

`extract` accepts directories only and refuses existing destinations. A full
root extraction on the default case-insensitive macOS filesystem fails before
creating output because this firmware legitimately contains both
`LICENSE.txt` and `License.txt`; use a case-sensitive extraction filesystem for
an exact full tree. Extracting libraries or passing the self-test establishes
byte provenance only—it is not an active-mapper oracle and does not enable the
colour presenter.

## Disposable offline exact-mapper oracle

`run_xochitl_mapper_oracle.py` and `xochitl_mapper_oracle.gdb` prepare a
diagnostic-only direct call to the installed Xochitl 3.27.1.0 active mapper.
This path has no device address, SSH command, attach mode, or presenter hook.
It starts a new inferior in a disposable `linux/arm64` container, never enters
real main, and kills that inferior after one call. The host GDB remote protocol
travels over gdbserver's standard I/O, so the container uses `--network none`
and opens no port. Its only host mounts are the exact Xochitl binary, extracted
firmware `/usr/lib`, and gdbserver, all read-only. Docker drops every container
capability and adds back only `SYS_PTRACE` for the child debugger.

This is now an **executed disposable direct-call oracle**, not a stock-device
capture or optical result. On 2026-07-11 the pinned runtime completed minimal
one-/two-row calls, full-production A/B geometry, three panel-corner calls, and
an asymmetric local-source fixture. The orchestrator writes
`oracle-manifest.json` only when the exact runtime execution, post-store dump,
descriptor restoration, output validation, and disposable container teardown
all succeed. Each new run starts unproven; an older manifest does not validate
different inputs or geometry.

### Pinned provenance

```text
Xochitl size:                 23059080
Xochitl SHA-256:              4646e0aef1cef2b3417889073ad5faba9259ae6b41f68326e75ef9a5c520c322
Xochitl Build ID:             f04525824e27e75d7a579b18c4007a3a76384789
mapper range:                 [0x004814a0, 0x00483b30)
mapper file offset/size:      0x814a0 / 0x2690
mapper range SHA-256:         3526e104129db479e5218f5f54a9fed2d7b655a6a8632b9d0868f54dfa0859fc
loader-ready main thunk:      0x00483b34
first post-store instruction: 0x00483280
fixed A/B descriptor:         0x01a18fd8
firmware loader SHA-256:      fc5d445d078240e4f04eed22db5426da1ecab3930a75f5641461a7590e6842b5
firmware libc SHA-256:        976c467f2c03c31ca1c06589d96230c27efaac3f6f5a9073dd15502a0c700b0e
firmware /usr/lib tree hash:   205b06e3125567ecde92210d3e0f8b1cf51c3767cf912ea914a97c65840491b2
firmware /usr/lib contents:    1647 files, 219 directories, 236 symlinks, 192355517 file bytes
gdbserver SHA-256:             f5154a1d16d577c90d794199a2bacf66954e6306e4b09281fb7ca1ecaa2fe8be
gdbserver Build ID:            aef4fdb5d079d1465b448e24e764f148c3e76f2e
```

The tree hash covers entry type, relative pathname, regular-file size and
content hash, or literal symlink text. The runner accepts either a full
case-sensitive extraction with `root/usr/lib` or the extractor's isolated
`/usr/lib` subtree, but the resulting tree must match all counts and the hash
above. Immediately before the debugger starts, the exact firmware loader runs
`--list --inhibit-cache`; every direct `DT_NEEDED` name must appear and every
resolved absolute file must be below the mounted firmware `/usr/lib`. Each
resolved file is hashed into the preflight record. All binary, rootfs, and
input identities are checked again after the call to close bind-mount races.

### Exact input contract

The runner does not invent a waveform table, palette, ct33 plane, or persistent
A/B history. Supply captured inputs or explicitly authored synthetic test
vectors; their meaning remains part of the experiment. It checks and records
their exact hashes. Lengths for minimal geometry are:

| Update rows | Phase-aligned storage rows | Palette | ct33 (`stride=8`) | delta | A/B (`stride=8` pixels) | output (`stride=16` u16) | aligned arena |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 3 | 16 | 24 | 2048 | 96 | 96 | 3264 (`0xcc0`) |
| 2 | 2 | 16 | 16 | 2048 | 64 | 64 | 3184 (`0xc70`) |

The inclusive update is `(left=0, top=0, right=0, bottom=rows-1)`. These sizes
come from a second access-bound audit, not the stock constructor's larger
allocation formula. At `0x004815bc` the mapper computes phase
`p = row_count & 1`. For width one, the scalar path entered at `0x004829a0`
loads ct33 and interleaved A/B rows `p` and `p+1`; the final stores at
`0x0048326c..0x0048327c` write those same A/B and output rows. Storage must
therefore cover indices `0..p+1`: three rows for a one-row update and two rows
for a two-row update. Every arena object is 16-byte aligned. The GDB script
fills complete 0x30-byte source/output/A-B descriptors, a 0x38-byte wave
object, and the closed subset of the 0xb0-byte context. It passes literal
`x4=0`, which skips the entry barrier.

`--panel-rect LEFT TOP WIDTH HEIGHT` instead installs the production A/B
descriptor (`968*1698*4 = 6,574,656` bytes), a redzoned 960x1696 ct33 safety
allocation (`1,628,160` bytes), and an output allocation with
`stride=align_up(WIDTH+8,8)` and `2*(HEIGHT+2)*stride` bytes. Crucially, the
direct mapper consumes `ctx+0x10` as an **operation-local** source: its first
lane is input byte zero and its second row begins at `ctx+0x30` stride. LEFT
and TOP position A/B/output state; they do not advance the source pointer. The
panel-sized ct33 file is over-allocation for redzone-safe experiments, not
evidence that a stock operation's source descriptor begins at panel origin.

The direct entry rounds WIDTH up to eight lanes and HEIGHT up to two rows. A
1x1 call therefore reads/emits/commits 8x2 local lanes. The stock A/B guard
columns/rows safely contain rounded calls at right/bottom panel edges. Fixture
authors must initialize every rounded local source lane deliberately; leaving
padding at zero asks the mapper to process raw state zero there.

The arena figures include independent nonzero 64-byte redzones immediately
before and after palette, delta, ct33, A/B, and output. GDB dumps all ten at the
post-store stop and the validator requires byte-for-byte equality with the
staged canary pattern. This prevents a missed vector/guard write from silently
corrupting the next packed object and masquerading as valid output. Inputs
must also be nontrivial: success requires both an A/B transition and at least
one nonzero output byte. A zero/no-op fixture is rejected rather than recorded
as an exact-mapper result.

At `0x00483b34`, loader/libc/TLS and constructors are initialized. GDB then
uses a real inferior function call to `0x004814a0`, giving `paciasp`/`autiasp`
a valid return frame. A hardware breakpoint at `0x00483280` dumps the state
after all normal A/B and output stores, then automatically continues through
the unmodified epilogue. The fixed A/B descriptor is restored byte-for-byte
before the disposable process is killed.

### Run

Use a locally present `linux/arm64` image by an immutable repository digest;
a mutable tag is rejected and the tool uses `--pull=never`. The image supplies
only enough userland to execute the pinned gdbserver—the target program always
uses the mounted firmware loader and library closure.

```sh
TOOL=tools/device/diagnostics/swtcon/run_xochitl_mapper_oracle.py
ROOTFS=/private/tmp/rm-fw-3.27.1.0-usr-lib-offline-oracle-v3
IMAGE='ubuntu@sha256:<exact-local-linux-arm64-repository-digest>'

python3 "$TOOL" \
  --execute \
  --xochitl /private/tmp/xochitl-3.27.1.0 \
  --rootfs "$ROOTFS" \
  --gdbserver build/device-tools/pluto-gdbserver-aarch64 \
  --image "$IMAGE" \
  --rows 1 \
  --palette /private/tmp/oracle-input/palette.bin \
  --ct33 /private/tmp/oracle-input/ct33-row1.bin \
  --delta /private/tmp/oracle-input/delta.bin \
  --ab /private/tmp/oracle-input/ab-row1.bin \
  --output /private/tmp/xochitl-mapper-oracle-row1
```

Use a fresh, nonexistent output directory for each run. `--execute` is a
mandatory acknowledgement; there is no implicit launch. The safe success
sequence in `oracle.gdb.log` is exactly:

```text
ORACLE_MAIN_READY
ORACLE_CALL_BEGIN ... x4=0
ORACLE_POST_STORE ... hit=1
ORACLE_MAPPER_COMPLETE ... post_hits=1 disposition=post-store-kill
ORACLE_COMPLETE ... inferior_disposition=kill
```

`oracle.preflight.json` deliberately says execution is not yet proven. Only a
zero GDB exit, all markers in order, one post-store hit, exact-sized dumps,
input/loaded byte equality, intact redzones, a nonzero output and A/B change,
pointer/stride/rectangle checks, restored A/B descriptor, unchanged artifact
hashes, and proof that the named disposable container no longer exists produce
`oracle-manifest.json`. A loader failure,
constructor abort before main, unsupported inferior call, breakpoint miss,
timeout, malformed dump, or uncertain cleanup fails closed. In particular, a
preflight file or partial dump directory is not oracle evidence.

### Mode-7 and composed bridge sequences

`--mode7-sequence --temperature-c T` calls dispatcher `0x009af7c0` once with
a non-null source and once with a null source. `--bridge-sequence` accepts
three production-disconnected compositions:

- `legacy-fast-legacy`;
- `fast-legacy` (the quality call intentionally does not wait for a Fast
  continuation); and
- `fast-continuation-legacy` (requires and executes one pending continuation).

Use panel geometry and the authored normal-pattern fixture, for example:

```sh
FIXTURE=/private/tmp/pluto-xochitl-fixture-mode7-pattern-20260712-v1
python3 "$TOOL" \
  --execute \
  --xochitl /private/tmp/xochitl-3.27.1.0 \
  --rootfs "$ROOTFS" \
  --gdbserver build/device-tools/pluto-gdbserver-aarch64 \
  --image "$IMAGE" \
  --panel-rect 64 64 8 2 \
  --palette "$FIXTURE/palette.bin" \
  --ct33 "$FIXTURE/ct33.bin" \
  --delta "$FIXTURE/delta.bin" \
  --ab "$FIXTURE/ab.bin" \
  --bridge-sequence fast-continuation-legacy \
  --temperature-c 25 \
  --output /private/tmp/xochitl-fast-continuation-legacy-cold
```

Every call in a bridge sequence returns through the installed binary's real
signed epilogue. Before each legacy call the harness rebuilds the complete
source/update/stride/wave/output context, clears mode-7 routing bytes, restores
`ctx+0` after a null-source continuation, and reselects the supplied
palette/delta. Validation composes independent frozen legacy and Fast scalar
models and compares every full A/B and u16 output stage. It also requires that
the 0x7000-byte continuation owner differ only at pending byte `+0x6568`, that
legacy calls leave that owner unchanged, and that owner/A-B globals and all
redzones restore.

The final 25 C/38 C matrix contains six accepted v2 bundles under
`/private/tmp/pluto-xochitl-bridge-*-20260712-v2`, each carrying its own
manifest with exact stage, runner, and GDB-program hashes.
These are direct mapper-sequence goldens, not evidence of stock operation
scheduling, Pluto scan pre-emption, or optical colour.

The first asymmetric runtime golden used local source row `0..7` followed by
`7..0` for an absolute 1x1 update at `{64,64}`. It emitted the exact mode-2
palette rows `{2,12,4,20,8,16,24,28}` and reverse, and committed A/B over
absolute 8x2 extent `{64,64,71,65}`. This proves source origin, normal palette
mapping, and vector rounding.

`generate_xochitl_mapper_fixture.py` creates production-geometry, deterministic
inputs plus `expected.json` for the three state branches that are easiest to
misread in SIMD. Its ct33 payload is intentionally operation-local at offsets
`0` and `960`; A/B remains the full `968x1698` interleaved plane.

```sh
GEN=tools/device/diagnostics/swtcon/generate_xochitl_mapper_fixture.py
python3 "$GEN" --case force27 --output /private/tmp/xochitl-force27-input
python3 "$GEN" --case pair31 --output /private/tmp/xochitl-pair31-input
python3 "$GEN" --case set6_low_source --output /private/tmp/xochitl-set6-input
```

Run each with `--panel-rect 64 64 8 2` and the generated `palette.bin`,
`ct33.bin`, `delta.bin`, and `ab.bin`. Executed pinned-binary goldens prove:

- `force27`: transition 91 on all 16 lanes, `A2=2`, `B2=0xfffb`;
- `pair31`: focus transition 927, `A2=0x009c`, `B2=0x24`; and
- `set6_low_source`: transition 92 on all lanes, focus
  `A2=0x00dc/B2=0`.

The last result proves that bit-6 setup has no old-source-high operand, while
the pair result proves that pair31 suppresses bit-6 setup. A benign 8x4
single/split/reverse experiment is byte-identical, but an adversarial
neighbour-history fixture differs for top-first split while one-call and
bottom-first match. Generic worker equivalence is therefore false. Stock
selector provenance, selected-delta byte parity, operation-level Fast
scheduling/interruption, and optical colour remain open production gates. The
direct mode-7 source/continuation and legacy/Fast bridge sequences are closed.

The disconnected C++ delta builder has separate offline artifact evidence. For
panel waveform SHA-256
`80b8174773effceefbc16b54722cc0afd2187bd9a7c260a71bfbf92baeae8b67`,
mode 2/bin 4 decodes to 86 phases and the complete 2048-byte table hashes to
`67cd71ab2481606a72a302cd069a29167aab0d703ea22283d6b746475f447492`,
matching the independent oracle fingerprint. The currently armed stock capture
has not yet produced an accepted live `cap.delta.bin`, so selected-record
provenance remains open even though offline builder parity has no mismatch.

Run the host-only tests without Docker or device access:

```sh
python3 -m unittest -v \
  tools/device/diagnostics/swtcon/test/test_run_xochitl_mapper_oracle.py \
  tools/device/diagnostics/swtcon/test/test_generate_xochitl_mapper_fixture.py
```
