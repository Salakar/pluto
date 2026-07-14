set pagination off
set confirm off
set breakpoint pending off
set architecture aarch64
# The attached Move's kernel/gdbserver cannot discover the architectural
# hardware-breakpoint count and accepts only one hbreak.  Three boundaries must
# be armed together to make the pre/worker/post snapshot atomic, so use ordinary
# software breakpoints deliberately.  The orchestrator independently proves
# that all three original four-byte instructions are restored after detach.
set breakpoint auto-hw off
set logging file cap.gdb.log
set logging overwrite on
set logging enabled on

python
import gdb
def _pluto_detach_on_quit():
    try:
        inferior = gdb.selected_inferior()
        if inferior is not None and inferior.pid:
            gdb.execute("detach")
    except gdb.error as error:
        gdb.write("CAPTURE_CLEANUP_ERROR: %s\n" % error, gdb.STDERR)
end

define hook-quit
  python _pluto_detach_on_quit()
end

python print("TARGET_GDB_PID: %d" % gdb.selected_inferior().pid)

set $capture_ready = 0
set $capture_thread = 0
set $capture_valid = 0
set $mapper_hits = 0
set $mapper_contract_error = 0
set $foreign_mapper_hit = 0
set $ctx = 0

# Post-worker breakpoint: the scheduling thread has waited for every worker.
break *0x009ade2c
set $post_breakpoint = $bpnum
commands
  silent
  if $capture_ready == 0 || $_thread != $capture_thread
    continue
  end

  set $capture_valid = 1
  set $out = *(void**)($ctx+0x70)
  set $ob = 0
  set $oe = 0
  set $out_bytes = 0
  if $out == 0
    set $capture_valid = 0
    printf "CAPTURE_REJECT: null post-worker output descriptor\n"
  else
    set $ob = *(void**)$out
    set $oe = *(void**)($out+8)
    set $oc = *(void**)($out+0x10)
    set $out_left = *(int*)($out+0x18)
    set $out_top = *(int*)($out+0x1c)
    set $out_right = *(int*)($out+0x20)
    set $out_bottom = *(int*)($out+0x24)
    set $out_stride = *(unsigned long long*)($out+0x28)
    set $update_left = *(int*)($ctx+0x38)
    set $update_top = *(int*)($ctx+0x3c)
    set $update_right = *(int*)($ctx+0x40)
    set $update_bottom = *(int*)($ctx+0x44)
    set $expected_out_stride = ($update_right-$update_left+16) & ~7
    set $expected_out_bytes = ($update_bottom-$update_top+3)*$expected_out_stride*2
    if $ob == 0 || $oe <= $ob || $oc < $oe || $expected_out_bytes <= 0 || $expected_out_bytes > 0x800000
      set $capture_valid = 0
      printf "CAPTURE_REJECT: invalid post-worker output span begin=0x%lx end=0x%lx\n", $ob, $oe
    else
      if $out_left != $update_left || $out_top != $update_top || $out_right != $update_right || $out_bottom != $update_bottom || $out_stride != $expected_out_stride || ((char*)$oe-(char*)$ob) != $expected_out_bytes
        set $capture_valid = 0
        printf "CAPTURE_REJECT: output descriptor disagrees with constructor contract\n"
      else
        set $out_bytes = (char*)$oe-(char*)$ob
        dump binary memory cap.outdesc.bin $out $out+0x30
        dump binary memory cap.out.bin $ob $oe
      end
    end
  end
  set $ab = *(void**)0x01a18fd8
  set $ab_end = *(void**)0x01a18fe0
  set $ab_capacity = *(void**)0x01a18fe8
  set $ab_left = *(int*)0x01a18ff0
  set $ab_top = *(int*)0x01a18ff4
  set $ab_right = *(int*)0x01a18ff8
  set $ab_bottom = *(int*)0x01a18ffc
  set $ab_stride = *(unsigned long long*)0x01a19000
  set $ab_bytes = 0
  if $ab == 0 || $ab_end <= $ab || $ab_capacity < $ab_end || ((char*)$ab_end-(char*)$ab) != 0x645240 || $ab_left != 0 || $ab_top != 0 || $ab_right != 959 || $ab_bottom != 1695 || $ab_stride != 968 || $ab != $ab_begin_pre || $ab_end != $ab_end_pre
    set $capture_valid = 0
    printf "CAPTURE_REJECT: invalid or changed post-worker A/B descriptor\n"
  else
    set $ab_bytes = (char*)$ab_end-(char*)$ab
    dump binary memory cap.ab.after.bin $ab $ab_end
  end

  if $mapper_hits == 0 || $mapper_hits > 2
    set $capture_valid = 0
    printf "CAPTURE_REJECT: active mapper hit count is %d, expected 1 or 2\n", $mapper_hits
  end
  if $foreign_mapper_hit != 0
    set $capture_valid = 0
    printf "CAPTURE_REJECT: a foreign mapper context ran during capture\n"
  end
  if $mapper_contract_error != 0
    set $capture_valid = 0
    printf "CAPTURE_REJECT: mapper workers disagreed on the captured ABI\n"
  end
  if $mapper_ctx != $ctx
    set $capture_valid = 0
    printf "CAPTURE_REJECT: mapper ctx 0x%lx != operation ctx 0x%lx\n", $mapper_ctx, $ctx
  end

  set $final_valid = $capture_valid
  set $final_hits = $mapper_hits
  set $final_out_bytes = $out_bytes
  set $final_ab_bytes = $ab_bytes
  detach
  printf "CAPTURE_COMPLETE: mapper_hits=%d out_bytes=0x%lx ab_bytes=0x%lx valid=%d detached=1\n", $final_hits, $final_out_bytes, $final_ab_bytes, $final_valid
  if $final_valid == 1
    quit 0
  else
    quit 2
  end
end
disable $post_breakpoint

# Mapper breakpoint: proof only. Pre-state was captured before workers started.
break *0x004814a0
set $mapper_breakpoint = $bpnum
commands
  silent
  if $capture_ready == 1
    if $x0 != $ctx
      set $foreign_mapper_hit = 1
      printf "MAPPER_FOREIGN: ctx=0x%lx expected=0x%lx\n", $x0, $ctx
    else
      set $current_mapper_out = *(void**)($x0+0x70)
      if $x1 == 0 || $w3 < $w2 || $x1 != $expected_palette || $current_mapper_out == 0
        set $mapper_contract_error = 1
        printf "MAPPER_REJECT: palette=0x%lx expected=0x%lx rows=%u..%u out=0x%lx\n", $x1, $expected_palette, $w2, $w3, $current_mapper_out
      else
        set $mapper_hits = $mapper_hits + 1
        if $mapper_hits == 1
          set $mapper_ctx = $x0
          set $mapper_palette = $x1
          set $mapper_barrier = $x4
          set $mapper_out = $current_mapper_out
          set $mapper_y_first = $w2
          set $mapper_y_last = $w3
          dump binary memory cap.ctx.bin $x0 $x0+0xb0
          dump binary memory cap.palette.bin $x1 $x1+0x10
        else
          if $x1 != $mapper_palette || $x4 != $mapper_barrier || $current_mapper_out != $mapper_out
            set $mapper_contract_error = 1
            printf "MAPPER_REJECT: palette or barrier changed across workers\n"
          end
        end
        printf "MAPPER_HIT %d: ctx=0x%lx palette=0x%lx rows=%u..%u barrier=0x%lx out=0x%lx\n", $mapper_hits, $x0, $x1, $w2, $w3, $x4, $current_mapper_out
      end
    end
  end
  continue
end

# Pre-worker breakpoint: reject unrelated/multi-op work and
# keep waiting until one eligible Content/UI operation arrives.
break *0x009adbd0
set $pre_breakpoint = $bpnum
commands
  silent
  set $list = $x0
  set $node = *(void**)$list
  if $node == $list
    printf "CAPTURE_SKIP: empty operation list at 0x%lx\n", $list
    continue
  end
  set $next = *(void**)$node
  if $next != $list
    printf "CAPTURE_SKIP: multi-operation list node=0x%lx next=0x%lx list=0x%lx\n", $node, $next, $list
    continue
  end
  set $candidate_ctx = $node+0x10
  set $src = *(void**)$candidate_ctx
  if $src == 0
    printf "CAPTURE_SKIP: null source descriptor ctx=0x%lx\n", $candidate_ctx
    continue
  end
  set $src_begin = *(void**)$src
  set $src_end = *(void**)($src+8)
  if $src_begin == 0 || $src_end <= $src_begin || ((char*)$src_end-(char*)$src_begin) > 0x400000
    printf "CAPTURE_SKIP: invalid source span begin=0x%lx end=0x%lx\n", $src_begin, $src_end
    continue
  end
  set $ct = *(void**)($candidate_ctx+0x10)
  set $mode = *(short*)($candidate_ctx+0x68)
  set $skip_kind = *(int*)($node+0xb4)
  set $flag_a0 = *(unsigned char*)($candidate_ctx+0xa0)
  set $flag_a1 = *(unsigned char*)($candidate_ctx+0xa1)
  set $flag_a2 = *(unsigned char*)($candidate_ctx+0xa2)

  if $skip_kind == 0x16 || $ct != $src_begin || ($mode != 2 && $mode != 5) || $flag_a0 != 0 || $flag_a1 != 0
    printf "CAPTURE_SKIP: node=0x%lx next=0x%lx list=0x%lx kind=0x%x ct=0x%lx begin=0x%lx mode=%d flags=%u/%u/%u\n", $node, $next, $list, $skip_kind, $ct, $src_begin, $mode, $flag_a0, $flag_a1, $flag_a2
    continue
  end
  set $palette_override = $flag_a2 & 1
  set $expected_palette = 0x014fb560 + ($palette_override != 0 ? 0x30 : $mode*16)

  set $ctx = $candidate_ctx
  set $wave = *(void**)($ctx+0x58)
  if $wave == 0
    printf "CAPTURE_SKIP: null selected waveform ctx=0x%lx\n", $ctx
    continue
  end
  set $delta = *(void**)($wave+0x30)
  if $delta == 0
    printf "CAPTURE_SKIP: null delta table wave=0x%lx\n", $wave
    continue
  end
  set $ab = *(void**)0x01a18fd8
  set $ab_end = *(void**)0x01a18fe0
  set $ab_capacity = *(void**)0x01a18fe8
  set $ab_left = *(int*)0x01a18ff0
  set $ab_top = *(int*)0x01a18ff4
  set $ab_right = *(int*)0x01a18ff8
  set $ab_bottom = *(int*)0x01a18ffc
  set $ab_stride = *(unsigned long long*)0x01a19000

  if $ab == 0 || $ab_end <= $ab || $ab_capacity < $ab_end || ((char*)$ab_end-(char*)$ab) != 0x645240 || $ab_left != 0 || $ab_top != 0 || $ab_right != 959 || $ab_bottom != 1695 || $ab_stride != 968
    printf "CAPTURE_SKIP: invalid A/B descriptor begin=0x%lx end=0x%lx stride=%lu\n", $ab, $ab_end, $ab_stride
    continue
  end
  set $capture_thread = $_thread
  set $capture_ready = 1
  set $mapper_hits = 0
  set $mapper_ctx = 0
  set $mapper_contract_error = 0
  set $foreign_mapper_hit = 0
  set $ab_begin_pre = $ab
  set $ab_end_pre = $ab_end

  dump binary memory cap.srcdesc.bin $src $src+0x30
  dump binary memory cap.ct33.bin $ct $ct+($src_end-$src_begin)
  dump binary memory cap.delta.bin $delta $delta+0x800
  dump binary memory cap.wavedesc.bin $wave $wave+0x38
  dump binary memory cap.abdesc.bin 0x01a18fd8 0x01a19008
  dump binary memory cap.ab.before.bin $ab $ab_end

  printf "CAPTURE_START: thread=%d ctx=0x%lx mode=%d ct33_bytes=0x%lx src=0x%lx out_pending=1 wave=0x%lx delta=0x%lx ab_bytes=0x%lx palette_override=%d expected_palette=0x%lx\n", $capture_thread, $ctx, $mode, (char*)*(void**)($src+8)-(char*)*(void**)$src, $src, $wave, $delta, (char*)$ab_end-(char*)$ab, $palette_override, $expected_palette
  disable $pre_breakpoint
  enable $post_breakpoint
  continue
end

printf "Waiting for one isolated Content/UI operation; cause one small stock UI update now.\n"
continue
