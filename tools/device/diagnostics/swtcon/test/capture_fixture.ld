ENTRY(_start)

PHDRS {
  text PT_LOAD FLAGS(5);
  data PT_LOAD FLAGS(6);
}

SECTIONS {
  . = 0x00400000;
  .text.start : {
    KEEP(*(.text.start))
    *(.text)
    *(.text.*)
  } :text

  . = 0x004814a0;
  .mapper : { KEEP(*(.mapper)) } :text

  . = 0x009adbd0;
  .preworker : { KEEP(*(.preworker)) } :text

  . = 0x009ade2c;
  .postworker : { KEEP(*(.postworker)) } :text

  . = 0x01000000;
  .testdata : { *(.testdata) } :data

  . = 0x014fb560;
  .palette : { *(.palette) } :data

  . = 0x01a18fd8;
  .abdesc : { *(.abdesc) } :data

  . = ALIGN(0x1000);
  .abdata (NOLOAD) : { *(.abdata) } :data

  /DISCARD/ : {
    *(.comment)
    *(.note*)
    *(.eh_frame*)
  }
}
