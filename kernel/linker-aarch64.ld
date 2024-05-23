TARGET(elf64-aarch64)
ENTRY(_start)

PHDRS {
    text PT_LOAD FLAGS((1 << 0) | (1 << 2)); /* r-x */
    rodata PT_LOAD FLAGS((1 << 2)); /* r-- */
    data PT_LOAD FLAGS((1 << 1) | (1 << 2)); /* rw- */
    dynamic PT_DYNAMIC FLAGS((1 << 1) | (1 << 2)); /* rw- */
}

SECTIONS {
    . = 0xffffffff80000000;

    .text : {
        *(.text .text.*)
    } :text
    
    . = ALIGN(4096);

    . += CONSTANT(MAXPAGESIZE);
    
    . = ALIGN(4096);

    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    . = ALIGN(4096);

    .data : {
        *(.data .data.*)
    } :data

    . = ALIGN(4096);

    .dynamic : {
        *(.dynamic .dynamic.*)
    } :dynamic

    . = ALIGN(4096);

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    /DISCARD/ : {
        *(.eh_frame)
        *(.note .note.*)
    }
}
