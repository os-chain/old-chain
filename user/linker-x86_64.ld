TARGET(elf64-x86-64)
ENTRY(_start)

SECTIONS {
    . = 0x200000;

    .text : {
        *(.text)
    }

    .data : {
        *(.data)
    }
}
