# Exact Xochitl 3.27.1.0 disposable active-mapper oracle.
#
# This script is intentionally not a standalone device script.  The Python
# orchestrator verifies all identities, supplies the checked $oracle_* layout
# values, connects to the stdio gdbserver, and validates every dump afterward.

set pagination off
set confirm off
set breakpoint pending off
set breakpoint always-inserted on
set architecture aarch64
set auto-solib-add on
set exec-file-mismatch warn
set logging file oracle.gdb.log
set logging overwrite on
set logging enabled on

define oracle_abort
  printf "ORACLE_REJECT code=%d pc=0x%lx\n", $arg0, $pc
  kill
  quit $arg0
end

if $oracle_profile != 0 && $oracle_profile != 1
  oracle_abort 41
end
if $oracle_rows <= 0 || $oracle_rows != $oracle_update_bottom-$oracle_update_top+1
  oracle_abort 42
end
if $oracle_y_first != $oracle_update_top || $oracle_y_last != $oracle_update_bottom
  oracle_abort 43
end
if $oracle_split_row != -1
  if $oracle_split_row <= $oracle_y_first || $oracle_split_row > $oracle_y_last
    oracle_abort 69
  end
  if (($oracle_split_row-$oracle_y_first)&1) != 0 || (($oracle_y_last-$oracle_split_row+1)&1) != 0
    oracle_abort 70
  end
end
if ($oracle_split_reverse != 0 && $oracle_split_reverse != 1) || ($oracle_split_row == -1 && $oracle_split_reverse != 0)
  oracle_abort 72
end
if $oracle_source_stride <= 0 || $oracle_ab_stride <= 0 || $oracle_output_stride <= 0
  oracle_abort 44
end
if $oracle_source_left > $oracle_source_right || $oracle_source_top > $oracle_source_bottom
  oracle_abort 45
end
if $oracle_redzone_bytes != 64
  oracle_abort 46
end
if $oracle_profile == 0
  if ($oracle_rows != 1 && $oracle_rows != 2) || $oracle_storage_rows != (($oracle_rows & 1)+2)
    oracle_abort 59
  end
  if $oracle_source_left != 0 || $oracle_source_top != 0 || $oracle_source_right != 7 || $oracle_source_bottom != $oracle_storage_rows-1 || $oracle_source_stride != 8
    oracle_abort 60
  end
  if $oracle_ab_left != 0 || $oracle_ab_top != 0 || $oracle_ab_right != 7 || $oracle_ab_bottom != $oracle_storage_rows-1 || $oracle_ab_stride != 8
    oracle_abort 61
  end
  if $oracle_update_left != 0 || $oracle_update_top != 0 || $oracle_update_right != 0 || $oracle_update_bottom != $oracle_rows-1 || $oracle_output_stride != 16
    oracle_abort 62
  end
  if $oracle_ct33_bytes != $oracle_storage_rows*8 || $oracle_ab_bytes != $oracle_storage_rows*32 || $oracle_output_bytes != $oracle_storage_rows*32
    oracle_abort 63
  end
else
  if $oracle_storage_rows != 1696 || $oracle_source_left != 0 || $oracle_source_top != 0 || $oracle_source_right != 959 || $oracle_source_bottom != 1695 || $oracle_source_stride != 960
    oracle_abort 64
  end
  if $oracle_ab_left != 0 || $oracle_ab_top != 0 || $oracle_ab_right != 959 || $oracle_ab_bottom != 1695 || $oracle_ab_stride != 968
    oracle_abort 65
  end
  if $oracle_update_left < 0 || $oracle_update_top < 0 || $oracle_update_right > 959 || $oracle_update_bottom > 1695 || $oracle_update_left > $oracle_update_right || $oracle_update_top > $oracle_update_bottom
    oracle_abort 66
  end
  if $oracle_output_stride != (($oracle_update_right-$oracle_update_left+16)&-8)
    oracle_abort 67
  end
  if $oracle_ct33_bytes != 1628160 || $oracle_ab_bytes != 6574656 || $oracle_output_bytes != 2*($oracle_rows+2)*$oracle_output_stride
    oracle_abort 68
  end
end

# Raw ELF entry is deliberately not used: reaching this thunk proves the
# firmware loader, libc, TLS and constructors have initialized.
hbreak *0x00483b34
set $main_breakpoint = $bpnum
continue
if $pc != 0x00483b34
  oracle_abort 47
end
disable $main_breakpoint
delete $main_breakpoint
printf "ORACLE_MAIN_READY pc=0x%lx\n", $pc

# One calloc keeps every synthetic object in one disposable, aligned arena.
# The cast is mandatory because the stripped inferior exposes only a minimal
# symbol for calloc.  glibc malloc alignment is checked, never assumed.
set $arena = (unsigned long) ((void *(*)(unsigned long, unsigned long)) calloc)(1, $oracle_arena_bytes)
if $arena == 0 || ($arena & 0xf) != 0
  oracle_abort 48
end

set $ctx = $arena
set $src = $ctx+0xb0
set $wave = $src+0x30
set $outdesc = $wave+0x40
set $palette = $arena+$oracle_palette_offset
set $delta = $arena+$oracle_delta_offset
set $ct33 = $arena+$oracle_ct33_offset
set $ab = $arena+$oracle_ab_offset
set $output = $arena+$oracle_output_offset
if $palette-$oracle_redzone_bytes < $outdesc+0x30
  oracle_abort 49
end
if $palette+0x10+$oracle_redzone_bytes > $delta-$oracle_redzone_bytes
  oracle_abort 50
end
if $delta+0x800+$oracle_redzone_bytes > $ct33-$oracle_redzone_bytes
  oracle_abort 51
end
if $ct33+$oracle_ct33_bytes+$oracle_redzone_bytes > $ab-$oracle_redzone_bytes
  oracle_abort 52
end
if $ab+$oracle_ab_bytes+$oracle_redzone_bytes > $output-$oracle_redzone_bytes
  oracle_abort 53
end
if $output+$oracle_output_bytes+$oracle_redzone_bytes > $arena+$oracle_arena_bytes
  oracle_abort 54
end
if (($ctx | $src | $wave | $outdesc | $palette | $delta | $ct33 | $ab | $output) & 0xf) != 0
  oracle_abort 55
end

restore oracle.redzone.input.bin binary $palette-$oracle_redzone_bytes
restore oracle.redzone.input.bin binary $palette+0x10
restore oracle.redzone.input.bin binary $delta-$oracle_redzone_bytes
restore oracle.redzone.input.bin binary $delta+0x800
restore oracle.redzone.input.bin binary $ct33-$oracle_redzone_bytes
restore oracle.redzone.input.bin binary $ct33+$oracle_ct33_bytes
restore oracle.redzone.input.bin binary $ab-$oracle_redzone_bytes
restore oracle.redzone.input.bin binary $ab+$oracle_ab_bytes
restore oracle.redzone.input.bin binary $output-$oracle_redzone_bytes
restore oracle.redzone.input.bin binary $output+$oracle_output_bytes
restore oracle.palette.input.bin binary $palette
restore oracle.ct33.input.bin binary $ct33
restore oracle.delta.input.bin binary $delta
restore oracle.ab.input.bin binary $ab
# This is the immutable pre-call A/B snapshot.  It must be taken here: the
# post-store breakpoint is intentionally after the mapper has mutated A/B.
dump binary memory oracle.ab.before.loaded.bin $ab $ab+$oracle_ab_bytes

# Source descriptor spans either the phase-aligned minimal fixture or a
# maximum-size, independently redzoned safety buffer. Runtime patterns prove
# the mapper treats ctx+0x10 as the operation-local origin; stock capture, not
# this over-allocation, establishes a real converter descriptor and stride.
set {unsigned long long}($src+0x00) = $ct33
set {unsigned long long}($src+0x08) = $ct33+$oracle_ct33_bytes
set {unsigned long long}($src+0x10) = $ct33+$oracle_ct33_bytes
set {int}($src+0x18) = $oracle_source_left
set {int}($src+0x1c) = $oracle_source_top
set {int}($src+0x20) = $oracle_source_right
set {int}($src+0x24) = $oracle_source_bottom
set {unsigned long long}($src+0x28) = $oracle_source_stride

# Wave object: the static back-slice reads only +0x30.
set {unsigned long long}($wave+0x30) = $delta

# Output descriptor: storage covers the exact phase-selected row pair; its
# logical rectangle remains the requested one/two-row update.
set {unsigned long long}($outdesc+0x00) = $output
set {unsigned long long}($outdesc+0x08) = $output+$oracle_output_bytes
set {unsigned long long}($outdesc+0x10) = $output+$oracle_output_bytes
set {int}($outdesc+0x18) = $oracle_update_left
set {int}($outdesc+0x1c) = $oracle_update_top
set {int}($outdesc+0x20) = $oracle_update_right
set {int}($outdesc+0x24) = $oracle_update_bottom
set {unsigned long long}($outdesc+0x28) = $oracle_output_stride

# Context fields read by 0x4814a0.  Wrapper-only fields stay calloc-zero,
# except mode=2 is retained as explicit bundle metadata.
set {unsigned long long}($ctx+0x00) = $src
set {unsigned long long}($ctx+0x10) = $ct33
set {int}($ctx+0x18) = $oracle_source_left
set {int}($ctx+0x1c) = $oracle_source_top
set {int}($ctx+0x20) = $oracle_source_right
set {int}($ctx+0x24) = $oracle_source_bottom
set {unsigned long long}($ctx+0x28) = $oracle_source_stride
set {unsigned long long}($ctx+0x30) = $oracle_source_stride
set {int}($ctx+0x38) = $oracle_update_left
set {int}($ctx+0x3c) = $oracle_update_top
set {int}($ctx+0x40) = $oracle_update_right
set {int}($ctx+0x44) = $oracle_update_bottom
set {unsigned long long}($ctx+0x58) = $wave
set {short}($ctx+0x68) = 2
set {unsigned long long}($ctx+0x70) = $outdesc

# The fixed global descriptor is process-local in this disposable inferior.
# Preserve and restore its complete 0x30 bytes even though the process is
# killed after the call.
dump binary memory oracle.abdesc.original.bin 0x01a18fd8 0x01a19008
set {unsigned long long}0x01a18fd8 = $ab
set {unsigned long long}0x01a18fe0 = $ab+$oracle_ab_bytes
set {unsigned long long}0x01a18fe8 = $ab+$oracle_ab_bytes
set {int}0x01a18ff0 = $oracle_ab_left
set {int}0x01a18ff4 = $oracle_ab_top
set {int}0x01a18ff8 = $oracle_ab_right
set {int}0x01a18ffc = $oracle_ab_bottom
set {unsigned long long}0x01a19000 = $oracle_ab_stride

if $oracle_kind < 0 || $oracle_kind > 4
  oracle_abort 73
end

# Production-disconnected exact mode-7 sequence.  Both calls return through
# the dispatcher's real paciasp/autiasp epilogue to the initialized main thunk;
# no production process is targeted and the disposable inferior is killed below.
if $oracle_kind == 1
  if $oracle_split_row != -1 || $oracle_split_reverse != 0
    oracle_abort 74
  end
  set {short}($ctx+0x68) = 7
  set {float}($ctx+0x6c) = $oracle_temperature_c
  set {unsigned char}($ctx+0xaa) = 1

  # The loader-ready disposable main thunk has not constructed the framebuffer
  # owner reached through 0x01a0d3a8.  A source lane with continuation flags
  # writes only owner+0x6568 at 0x009b09d0.  Install a redzoned zeroed owner,
  # preserve the fixed pointer, and prove/restore it before killing the inferior.
  dump binary memory oracle.fast-global-pointer.original.bin 0x01a0d3a8 0x01a0d3b0
  set $fast_owner_allocation = (unsigned long) ((void *(*)(unsigned long, unsigned long)) calloc)(1, 0x7080)
  if $fast_owner_allocation == 0 || ($fast_owner_allocation & 0xf) != 0
    oracle_abort 77
  end
  set $fast_owner = $fast_owner_allocation+0x40
  restore oracle.redzone.input.bin binary $fast_owner-0x40
  restore oracle.redzone.input.bin binary $fast_owner+0x7000
  set {unsigned long long}0x01a0d3a8 = $fast_owner
  dump binary memory oracle.fast-global.before-source.bin $fast_owner $fast_owner+0x7000

  hbreak *0x00483b34
  set $fast_return_breakpoint = $bpnum
  set scheduler-locking on

  printf "ORACLE_FAST_SOURCE_BEGIN entry=0x009af7c0 ctx=0x%lx temperature_bits=0x%x worker=0/1\n", $ctx, {unsigned int}($ctx+0x6c)
  set $x0 = $ctx
  set $w1 = 0
  set $w2 = 1
  set $x3 = 0
  set $x30 = 0x00483b34
  set $pc = 0x009af7c0
  continue
  if $pc != 0x00483b34
    oracle_abort 75
  end
  dump binary memory oracle.ctx.after-source.bin $ctx $ctx+0xb0
  dump binary memory oracle.ab.after-source.bin $ab $ab+$oracle_ab_bytes
  dump binary memory oracle.output.after-source.bin $output $output+$oracle_output_bytes
  dump binary memory oracle.fast-global.after-source.bin $fast_owner $fast_owner+0x7000
  printf "ORACLE_FAST_SOURCE_COMPLETE return=0x%lx\n", $pc

  restore oracle.output.zero.bin binary $output
  set {unsigned char}($fast_owner+0x6568) = 0
  dump binary memory oracle.fast-global.before-continuation.bin $fast_owner $fast_owner+0x7000
  set {unsigned long long}($ctx+0x00) = 0
  printf "ORACLE_FAST_CONTINUATION_BEGIN entry=0x009af7c0 ctx=0x%lx source=0 worker=0/1\n", $ctx
  set $x0 = $ctx
  set $w1 = 0
  set $w2 = 1
  set $x3 = 0
  set $x30 = 0x00483b34
  set $pc = 0x009af7c0
  continue
  if $pc != 0x00483b34
    oracle_abort 76
  end

  dump binary memory oracle.ctx.bin $ctx $ctx+0xb0
  dump binary memory oracle.srcdesc.bin $src $src+0x30
  dump binary memory oracle.wavedesc.bin $wave $wave+0x38
  dump binary memory oracle.outdesc.bin $outdesc $outdesc+0x30
  dump binary memory oracle.abdesc.synthetic.bin 0x01a18fd8 0x01a19008
  dump binary memory oracle.palette.loaded.bin $palette $palette+0x10
  dump binary memory oracle.ct33.loaded.bin $ct33 $ct33+$oracle_ct33_bytes
  dump binary memory oracle.delta.loaded.bin $delta $delta+0x800
  dump binary memory oracle.ab.after-continuation.bin $ab $ab+$oracle_ab_bytes
  dump binary memory oracle.output.after-continuation.bin $output $output+$oracle_output_bytes
  dump binary memory oracle.fast-global.after-continuation.bin $fast_owner $fast_owner+0x7000
  dump binary memory oracle.redzone.fast-global.pre.bin $fast_owner-0x40 $fast_owner
  dump binary memory oracle.redzone.fast-global.post.bin $fast_owner+0x7000 $fast_owner+0x7040
  dump binary memory oracle.redzone.palette.pre.bin $palette-$oracle_redzone_bytes $palette
  dump binary memory oracle.redzone.palette.post.bin $palette+0x10 $palette+0x10+$oracle_redzone_bytes
  dump binary memory oracle.redzone.delta.pre.bin $delta-$oracle_redzone_bytes $delta
  dump binary memory oracle.redzone.delta.post.bin $delta+0x800 $delta+0x800+$oracle_redzone_bytes
  dump binary memory oracle.redzone.ct33.pre.bin $ct33-$oracle_redzone_bytes $ct33
  dump binary memory oracle.redzone.ct33.post.bin $ct33+$oracle_ct33_bytes $ct33+$oracle_ct33_bytes+$oracle_redzone_bytes
  dump binary memory oracle.redzone.ab.pre.bin $ab-$oracle_redzone_bytes $ab
  dump binary memory oracle.redzone.ab.post.bin $ab+$oracle_ab_bytes $ab+$oracle_ab_bytes+$oracle_redzone_bytes
  dump binary memory oracle.redzone.output.pre.bin $output-$oracle_redzone_bytes $output
  dump binary memory oracle.redzone.output.post.bin $output+$oracle_output_bytes $output+$oracle_output_bytes+$oracle_redzone_bytes
  printf "ORACLE_FAST_CONTINUATION_COMPLETE return=0x%lx\n", $pc

  restore oracle.abdesc.original.bin binary 0x01a18fd8
  dump binary memory oracle.abdesc.restored.bin 0x01a18fd8 0x01a19008
  restore oracle.fast-global-pointer.original.bin binary 0x01a0d3a8
  dump binary memory oracle.fast-global-pointer.restored.bin 0x01a0d3a8 0x01a0d3b0
  printf "ORACLE_FAST_SEQUENCE_COMPLETE entry=0x009af7c0 update=%d,%d,%d,%d disposition=kill\n", $oracle_update_left, $oracle_update_top, $oracle_update_right, $oracle_update_bottom
  kill
  quit 0
end

# Composed state-bridge sequences.  Kinds are deliberately separate so each
# bundle starts from the same immutable input A/B plane:
#   2 = legacy -> Fast source -> legacy (no Fast continuation)
#   3 = Fast source -> legacy (no Fast continuation)
#   4 = Fast source -> one pending continuation -> legacy
# Every call returns through its real signed epilogue.  Before each legacy
# call the complete direct-mapper context contract is rebuilt; in particular,
# kind 4 restores ctx+0 after the null-source continuation.
if $oracle_kind >= 2 && $oracle_kind <= 4
  if $oracle_split_row != -1 || $oracle_split_reverse != 0
    oracle_abort 78
  end

  dump binary memory oracle.fast-global-pointer.original.bin 0x01a0d3a8 0x01a0d3b0
  set $fast_owner_allocation = (unsigned long) ((void *(*)(unsigned long, unsigned long)) calloc)(1, 0x7080)
  if $fast_owner_allocation == 0 || ($fast_owner_allocation & 0xf) != 0
    oracle_abort 79
  end
  set $fast_owner = $fast_owner_allocation+0x40
  restore oracle.redzone.input.bin binary $fast_owner-0x40
  restore oracle.redzone.input.bin binary $fast_owner+0x7000
  set {unsigned long long}0x01a0d3a8 = $fast_owner

  hbreak *0x00483b34
  set $bridge_return_breakpoint = $bpnum
  set scheduler-locking on
  set {float}($ctx+0x6c) = $oracle_temperature_c
  printf "ORACLE_BRIDGE_BEGIN kind=%d ctx=0x%lx temperature_bits=0x%x update=%d,%d,%d,%d\n", $oracle_kind, $ctx, {unsigned int}($ctx+0x6c), $oracle_update_left, $oracle_update_top, $oracle_update_right, $oracle_update_bottom

  if $oracle_kind == 2
    # Rebuild a Content/Full legacy direct-mapper context from first principles.
    set {unsigned long long}($ctx+0x00) = $src
    set {unsigned long long}($ctx+0x10) = $ct33
    set {int}($ctx+0x18) = $oracle_source_left
    set {int}($ctx+0x1c) = $oracle_source_top
    set {int}($ctx+0x20) = $oracle_source_right
    set {int}($ctx+0x24) = $oracle_source_bottom
    set {unsigned long long}($ctx+0x28) = $oracle_source_stride
    set {unsigned long long}($ctx+0x30) = $oracle_source_stride
    set {int}($ctx+0x38) = $oracle_update_left
    set {int}($ctx+0x3c) = $oracle_update_top
    set {int}($ctx+0x40) = $oracle_update_right
    set {int}($ctx+0x44) = $oracle_update_bottom
    set {unsigned long long}($ctx+0x58) = $wave
    set {short}($ctx+0x68) = 2
    set {unsigned long long}($ctx+0x70) = $outdesc
    set {unsigned char}($ctx+0xa0) = 0
    set {unsigned char}($ctx+0xa1) = 0
    set {unsigned char}($ctx+0xa2) = 0
    set {unsigned char}($ctx+0xaa) = 0
    set {unsigned long long}($wave+0x30) = $delta
    restore oracle.output.zero.bin binary $output
    dump binary memory oracle.fast-global.before-legacy-before-fast.bin $fast_owner $fast_owner+0x7000
    printf "ORACLE_BRIDGE_LEGACY_BEFORE_FAST_BEGIN entry=0x004814a0\n"
    set $x0 = $ctx
    set $x1 = $palette
    set $w2 = $oracle_y_first
    set $w3 = $oracle_y_last
    set $x4 = 0
    set $x30 = 0x00483b34
    set $pc = 0x004814a0
    continue
    if $pc != 0x00483b34
      oracle_abort 80
    end
    dump binary memory oracle.ab.after-legacy-before-fast.bin $ab $ab+$oracle_ab_bytes
    dump binary memory oracle.output.after-legacy-before-fast.bin $output $output+$oracle_output_bytes
    dump binary memory oracle.fast-global.after-legacy-before-fast.bin $fast_owner $fast_owner+0x7000
    printf "ORACLE_BRIDGE_LEGACY_BEFORE_FAST_COMPLETE return=0x%lx\n", $pc
  end

  # Rebuild the mode-7 source context, independently of the preceding call.
  set {unsigned long long}($ctx+0x00) = $src
  set {unsigned long long}($ctx+0x10) = $ct33
  set {int}($ctx+0x18) = $oracle_source_left
  set {int}($ctx+0x1c) = $oracle_source_top
  set {int}($ctx+0x20) = $oracle_source_right
  set {int}($ctx+0x24) = $oracle_source_bottom
  set {unsigned long long}($ctx+0x28) = $oracle_source_stride
  set {unsigned long long}($ctx+0x30) = $oracle_source_stride
  set {int}($ctx+0x38) = $oracle_update_left
  set {int}($ctx+0x3c) = $oracle_update_top
  set {int}($ctx+0x40) = $oracle_update_right
  set {int}($ctx+0x44) = $oracle_update_bottom
  set {unsigned long long}($ctx+0x58) = $wave
  set {short}($ctx+0x68) = 7
  set {float}($ctx+0x6c) = $oracle_temperature_c
  set {unsigned long long}($ctx+0x70) = $outdesc
  set {unsigned char}($ctx+0xa0) = 0
  set {unsigned char}($ctx+0xa1) = 0
  set {unsigned char}($ctx+0xa2) = 0
  set {unsigned char}($ctx+0xaa) = 1
  restore oracle.output.zero.bin binary $output
  set {unsigned char}($fast_owner+0x6568) = 0
  dump binary memory oracle.fast-global.before-fast-source.bin $fast_owner $fast_owner+0x7000
  printf "ORACLE_BRIDGE_FAST_SOURCE_BEGIN entry=0x009af7c0\n"
  set $x0 = $ctx
  set $w1 = 0
  set $w2 = 1
  set $x3 = 0
  set $x30 = 0x00483b34
  set $pc = 0x009af7c0
  continue
  if $pc != 0x00483b34
    oracle_abort 81
  end
  dump binary memory oracle.ab.after-fast-source.bin $ab $ab+$oracle_ab_bytes
  dump binary memory oracle.output.after-fast-source.bin $output $output+$oracle_output_bytes
  dump binary memory oracle.fast-global.after-fast-source.bin $fast_owner $fast_owner+0x7000
  printf "ORACLE_BRIDGE_FAST_SOURCE_COMPLETE return=0x%lx pending=%d\n", $pc, {unsigned char}($fast_owner+0x6568)

  if $oracle_kind == 4
    if {unsigned char}($fast_owner+0x6568) == 0
      oracle_abort 82
    end
    restore oracle.output.zero.bin binary $output
    set {unsigned char}($fast_owner+0x6568) = 0
    set {unsigned long long}($ctx+0x00) = 0
    dump binary memory oracle.fast-global.before-fast-continuation.bin $fast_owner $fast_owner+0x7000
    printf "ORACLE_BRIDGE_FAST_CONTINUATION_BEGIN entry=0x009af7c0 source=0\n"
    set $x0 = $ctx
    set $w1 = 0
    set $w2 = 1
    set $x3 = 0
    set $x30 = 0x00483b34
    set $pc = 0x009af7c0
    continue
    if $pc != 0x00483b34
      oracle_abort 83
    end
    dump binary memory oracle.ab.after-fast-continuation.bin $ab $ab+$oracle_ab_bytes
    dump binary memory oracle.output.after-fast-continuation.bin $output $output+$oracle_output_bytes
    dump binary memory oracle.fast-global.after-fast-continuation.bin $fast_owner $fast_owner+0x7000
    printf "ORACLE_BRIDGE_FAST_CONTINUATION_COMPLETE return=0x%lx pending=%d\n", $pc, {unsigned char}($fast_owner+0x6568)
  end

  # Rebuild the complete legacy context again.  This deliberately restores
  # ctx+0 after kind 4's null-source continuation and clears mode-7 routing.
  set {unsigned long long}($ctx+0x00) = $src
  set {unsigned long long}($ctx+0x10) = $ct33
  set {int}($ctx+0x18) = $oracle_source_left
  set {int}($ctx+0x1c) = $oracle_source_top
  set {int}($ctx+0x20) = $oracle_source_right
  set {int}($ctx+0x24) = $oracle_source_bottom
  set {unsigned long long}($ctx+0x28) = $oracle_source_stride
  set {unsigned long long}($ctx+0x30) = $oracle_source_stride
  set {int}($ctx+0x38) = $oracle_update_left
  set {int}($ctx+0x3c) = $oracle_update_top
  set {int}($ctx+0x40) = $oracle_update_right
  set {int}($ctx+0x44) = $oracle_update_bottom
  set {unsigned long long}($ctx+0x58) = $wave
  set {short}($ctx+0x68) = 2
  set {unsigned long long}($ctx+0x70) = $outdesc
  set {unsigned char}($ctx+0xa0) = 0
  set {unsigned char}($ctx+0xa1) = 0
  set {unsigned char}($ctx+0xa2) = 0
  set {unsigned char}($ctx+0xaa) = 0
  set {unsigned long long}($wave+0x30) = $delta
  restore oracle.output.zero.bin binary $output
  dump binary memory oracle.fast-global.before-legacy-after-fast.bin $fast_owner $fast_owner+0x7000
  printf "ORACLE_BRIDGE_LEGACY_AFTER_FAST_BEGIN entry=0x004814a0\n"
  set $x0 = $ctx
  set $x1 = $palette
  set $w2 = $oracle_y_first
  set $w3 = $oracle_y_last
  set $x4 = 0
  set $x30 = 0x00483b34
  set $pc = 0x004814a0
  continue
  if $pc != 0x00483b34
    oracle_abort 84
  end
  dump binary memory oracle.ctx.bin $ctx $ctx+0xb0
  dump binary memory oracle.srcdesc.bin $src $src+0x30
  dump binary memory oracle.wavedesc.bin $wave $wave+0x38
  dump binary memory oracle.outdesc.bin $outdesc $outdesc+0x30
  dump binary memory oracle.abdesc.synthetic.bin 0x01a18fd8 0x01a19008
  dump binary memory oracle.palette.loaded.bin $palette $palette+0x10
  dump binary memory oracle.ct33.loaded.bin $ct33 $ct33+$oracle_ct33_bytes
  dump binary memory oracle.delta.loaded.bin $delta $delta+0x800
  dump binary memory oracle.ab.after-legacy-after-fast.bin $ab $ab+$oracle_ab_bytes
  dump binary memory oracle.output.after-legacy-after-fast.bin $output $output+$oracle_output_bytes
  dump binary memory oracle.fast-global.after-legacy-after-fast.bin $fast_owner $fast_owner+0x7000
  dump binary memory oracle.redzone.fast-global.pre.bin $fast_owner-0x40 $fast_owner
  dump binary memory oracle.redzone.fast-global.post.bin $fast_owner+0x7000 $fast_owner+0x7040
  dump binary memory oracle.redzone.palette.pre.bin $palette-$oracle_redzone_bytes $palette
  dump binary memory oracle.redzone.palette.post.bin $palette+0x10 $palette+0x10+$oracle_redzone_bytes
  dump binary memory oracle.redzone.delta.pre.bin $delta-$oracle_redzone_bytes $delta
  dump binary memory oracle.redzone.delta.post.bin $delta+0x800 $delta+0x800+$oracle_redzone_bytes
  dump binary memory oracle.redzone.ct33.pre.bin $ct33-$oracle_redzone_bytes $ct33
  dump binary memory oracle.redzone.ct33.post.bin $ct33+$oracle_ct33_bytes $ct33+$oracle_ct33_bytes+$oracle_redzone_bytes
  dump binary memory oracle.redzone.ab.pre.bin $ab-$oracle_redzone_bytes $ab
  dump binary memory oracle.redzone.ab.post.bin $ab+$oracle_ab_bytes $ab+$oracle_ab_bytes+$oracle_redzone_bytes
  dump binary memory oracle.redzone.output.pre.bin $output-$oracle_redzone_bytes $output
  dump binary memory oracle.redzone.output.post.bin $output+$oracle_output_bytes $output+$oracle_output_bytes+$oracle_redzone_bytes
  printf "ORACLE_BRIDGE_LEGACY_AFTER_FAST_COMPLETE return=0x%lx\n", $pc

  restore oracle.abdesc.original.bin binary 0x01a18fd8
  dump binary memory oracle.abdesc.restored.bin 0x01a18fd8 0x01a19008
  restore oracle.fast-global-pointer.original.bin binary 0x01a0d3a8
  dump binary memory oracle.fast-global-pointer.restored.bin 0x01a0d3a8 0x01a0d3b0
  printf "ORACLE_BRIDGE_COMPLETE kind=%d update=%d,%d,%d,%d disposition=kill\n", $oracle_kind, $oracle_update_left, $oracle_update_top, $oracle_update_right, $oracle_update_bottom
  kill
  quit 0
end

set $post_hits = 0
set $oracle_in_call = 0
set $oracle_calls = 1
if $oracle_split_row != -1
  set $oracle_calls = 2
end

# A split differential must return through the mapper's real signed epilogue
# between calls so its stack/TLS frame is retired.  paciasp signs this fixed
# return address on entry and autiasp authenticates it before ret.
hbreak *0x00483b34
set $return_breakpoint = $bpnum
commands
  silent
  if $oracle_calls != 2 || $post_hits != 1 || $oracle_in_call != 0 || $pc != 0x00483b34
    oracle_abort 71
  end
  if $oracle_split_reverse == 0
    set $oracle_active_first = $oracle_split_row
    set $oracle_active_last = $oracle_y_last
  else
    set $oracle_active_first = $oracle_y_first
    set $oracle_active_last = $oracle_split_row-1
  end
  set $oracle_in_call = 1
  set $x0 = $ctx
  set $x1 = $palette
  set $w2 = $oracle_active_first
  set $w3 = $oracle_active_last
  set $x4 = 0
  set $x30 = 0x00483b34
  set $pc = 0x004814a0
  continue
end

# This is the first instruction after every normal A/B and output store and is
# still before the signed epilogue/autiasp/ret sequence.
hbreak *0x00483280
set $post_breakpoint = $bpnum
commands
  silent
  if $oracle_in_call != 1 || $pc != 0x00483280
    oracle_abort 56
  end
  set $post_hits = $post_hits+1
  if $post_hits > $oracle_calls
    oracle_abort 57
  end
  if $post_hits < $oracle_calls
    printf "ORACLE_SPLIT_PART_COMPLETE call=%d rows=%d..%d disposition=signed-return\n", $post_hits, $oracle_active_first, $oracle_active_last
    set $oracle_in_call = 0
    continue
  end
  dump binary memory oracle.ctx.bin $ctx $ctx+0xb0
  dump binary memory oracle.srcdesc.bin $src $src+0x30
  dump binary memory oracle.wavedesc.bin $wave $wave+0x38
  dump binary memory oracle.outdesc.bin $outdesc $outdesc+0x30
  dump binary memory oracle.abdesc.synthetic.bin 0x01a18fd8 0x01a19008
  dump binary memory oracle.palette.loaded.bin $palette $palette+0x10
  dump binary memory oracle.ct33.loaded.bin $ct33 $ct33+$oracle_ct33_bytes
  dump binary memory oracle.delta.loaded.bin $delta $delta+0x800
  dump binary memory oracle.output.after.bin $output $output+$oracle_output_bytes
  dump binary memory oracle.ab.after.bin $ab $ab+$oracle_ab_bytes
  dump binary memory oracle.redzone.palette.pre.bin $palette-$oracle_redzone_bytes $palette
  dump binary memory oracle.redzone.palette.post.bin $palette+0x10 $palette+0x10+$oracle_redzone_bytes
  dump binary memory oracle.redzone.delta.pre.bin $delta-$oracle_redzone_bytes $delta
  dump binary memory oracle.redzone.delta.post.bin $delta+0x800 $delta+0x800+$oracle_redzone_bytes
  dump binary memory oracle.redzone.ct33.pre.bin $ct33-$oracle_redzone_bytes $ct33
  dump binary memory oracle.redzone.ct33.post.bin $ct33+$oracle_ct33_bytes $ct33+$oracle_ct33_bytes+$oracle_redzone_bytes
  dump binary memory oracle.redzone.ab.pre.bin $ab-$oracle_redzone_bytes $ab
  dump binary memory oracle.redzone.ab.post.bin $ab+$oracle_ab_bytes $ab+$oracle_ab_bytes+$oracle_redzone_bytes
  dump binary memory oracle.redzone.output.pre.bin $output-$oracle_redzone_bytes $output
  dump binary memory oracle.redzone.output.post.bin $output+$oracle_output_bytes $output+$oracle_output_bytes+$oracle_redzone_bytes
  printf "ORACLE_POST_STORE pc=0x%lx hit=%d output=0x%lx bytes=0x%lx ab=0x%lx bytes=0x%lx\n", $pc, $post_hits, $output, $oracle_output_bytes, $ab, $oracle_ab_bytes
  # The inferior is diagnostic-only and dies at this proven post-store
  # boundary.  Restore the process-global descriptor first so the dump proves
  # cleanup even though no production process is altered or resumed.
  restore oracle.abdesc.original.bin binary 0x01a18fd8
  dump binary memory oracle.abdesc.restored.bin 0x01a18fd8 0x01a19008
  printf "ORACLE_MAPPER_COMPLETE entry=0x004814a0 post_hits=%d disposition=post-store-kill\n", $post_hits
  printf "ORACLE_COMPLETE profile=%d update=%d,%d,%d,%d x4=0 inferior_disposition=kill\n", $oracle_profile, $oracle_update_left, $oracle_update_top, $oracle_update_right, $oracle_update_bottom
  kill
  quit 0
end

set $oracle_in_call = 1
printf "ORACLE_CALL_BEGIN entry=0x004814a0 ctx=0x%lx palette=0x%lx rows=%d..%d split=%d reverse=%d x4=0\n", $ctx, $palette, $oracle_y_first, $oracle_y_last, $oracle_split_row, $oracle_split_reverse

# Launch the normal mapper entry on the initialized main thread.  A GDB
# `call` expression cannot service a breakpoint inside its callee: it aborts
# expression evaluation before breakpoint commands execute.  Register launch
# avoids that debugger artifact while still entering at paciasp with the
# initialized thread's aligned stack/TLS.  Scheduler locking keeps every
# unrelated Xochitl thread stopped.  We intentionally never fake a return:
# the post-store breakpoint above validates and kills the disposable inferior
# before the epilogue, so x30 is irrelevant and no live process is altered.
set scheduler-locking on
set $oracle_active_first = $oracle_y_first
set $oracle_active_last = $oracle_y_last
if $oracle_split_row != -1
  if $oracle_split_reverse == 0
    set $oracle_active_last = $oracle_split_row-1
  else
    set $oracle_active_first = $oracle_split_row
  end
end
set $x0 = $ctx
set $x1 = $palette
set $w2 = $oracle_active_first
set $w3 = $oracle_active_last
set $x4 = 0
set $x30 = 0x00483b34
set $pc = 0x004814a0
continue

# Only an oracle_abort/quit or the post-store command list may end the run.
oracle_abort 58
