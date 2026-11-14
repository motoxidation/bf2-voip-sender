; sys.asm - the bits of linux we talk to, raw syscalls, plus a few string helpers

SYS_READ        equ 0
SYS_WRITE       equ 1
SYS_OPEN        equ 2
SYS_CLOSE       equ 3
SYS_FSTAT       equ 5
SYS_POLL        equ 7
SYS_MMAP        equ 9
SYS_SOCKET      equ 41
SYS_SENDTO      equ 44
SYS_EXIT        equ 60
SYS_CLOCK_GET   equ 228
SYS_CLOCK_SLEEP equ 230

CLOCK_MONOTONIC equ 1
EINTR           equ 4

section .data
s_prefix:   db "alger: ", 0
s_nl:       db 10, 0

section .bss
numbuf:     resb 24
ts:         resq 2

section .text

; rdi = string -> rax = length
strlen:
    xor eax, eax
.l:
    cmp byte [rdi+rax], 0
    je .d
    inc rax
    jmp .l
.d:
    ret

; rdi = string, esi = fd
fputs:
    push rdi
    push rsi
    call strlen
    mov rdx, rax
    pop rdi
    pop rsi
    mov eax, SYS_WRITE
    syscall
    ret

eputs:
    mov esi, 2
    jmp fputs

; rdi = message. "alger: message", exit 1
die:
    push rdi
    mov rdi, s_prefix
    call eputs
    pop rdi
    call eputs
    mov rdi, s_nl
    call eputs
    mov edi, 1
    mov eax, SYS_EXIT
    syscall

; rdi = message, rsi = what it is about. "alger: message what", exit 1
die2:
    push rsi
    push rdi
    mov rdi, s_prefix
    call eputs
    pop rdi
    call eputs
    pop rdi
    call eputs
    mov rdi, s_nl
    call eputs
    mov edi, 1
    mov eax, SYS_EXIT
    syscall

; rsi, rdi = strings -> ZF set if equal
streq:
    xor ecx, ecx
.l:
    mov al, [rsi+rcx]
    cmp al, [rdi+rcx]
    jne .d
    inc rcx
    test al, al
    jnz .l
.d:
    ret

; rdi = decimal string -> rax, CF set if it isn't one (or doesn't fit 32 bits)
parse_u:
    xor eax, eax
    cmp byte [rdi], 0
    je .bad
.l:
    movzx ecx, byte [rdi]
    test ecx, ecx
    jz .ok
    sub ecx, '0'
    cmp ecx, 9
    ja .bad
    imul rax, rax, 10
    add rax, rcx
    mov edx, 0xFFFFFFFF
    cmp rax, rdx
    ja .bad
    inc rdi
    jmp .l
.ok:
    clc
    ret
.bad:
    stc
    ret

; rax = value -> rdi = its decimal string (in numbuf)
utoa:
    lea rdi, [numbuf+23]
    mov byte [rdi], 0
    mov ecx, 10
.l:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test rax, rax
    jnz .l
    ret

; -> rax = monotonic clock in ns
now_ns:
    mov edi, CLOCK_MONOTONIC
    mov rsi, ts
    mov eax, SYS_CLOCK_GET
    syscall
    mov rax, [ts]
    imul rax, rax, 1000000000
    add rax, [ts+8]
    ret

; rdi = monotonic time in ns to sleep until. returns straight away if it's already past
sleep_until:
    mov rax, rdi
    xor edx, edx
    mov ecx, 1000000000
    div rcx
    mov [ts], rax
    mov [ts+8], rdx
.again:
    mov edi, CLOCK_MONOTONIC
    mov esi, 1                      ; TIMER_ABSTIME
    mov rdx, ts
    xor r10d, r10d
    mov eax, SYS_CLOCK_SLEEP
    syscall
    cmp eax, -EINTR
    je .again
    ret
