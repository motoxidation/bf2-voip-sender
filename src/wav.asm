; wav.asm - reads a wav and turns it into 8 kHz mono s16, whatever it was before.
; 16-bit pcm or 32-bit float, any number of channels, any rate. going down in rate, each
; output sample is the average of its slice of input. a box filter: crude, but it keeps
; most of the aliasing out and nobody on a squad channel is an audiophile.

section .data
align 8
k_8k:       dq 8000.0
k_s16:      dq 32767.0
k_s16lo:    dq -32768.0
s_wav_open: db "can't open that wav", 0
s_wav_bad:  db "that's not a wav file. alger knows a wav when he sees one", 0
s_wav_fmt:  db "alger reads 16-bit pcm or 32-bit float wav, nothing fancier", 0
s_wav_none: db "that wav has no sound in it", 0
s_nomem:    db "out of memory. how long is this wav?", 0

section .bss
alignb 8
statbuf:    resb 144
wav_ratio:  resq 1
wav_data:   resq 1
wav_bytes:  resq 1
wav_frames: resq 1
wav_out:    resq 1
wav_ch:     resd 1
wav_rate:   resd 1
wav_bits:   resd 1
wav_tag:    resd 1
wav_bps:    resd 1

section .text

; rdi = path -> rax = samples (s16, 8 kHz mono), rdx = how many
wav_load:
    push rbx
    push r12
    push r13
    push r14
    push r15
    xor esi, esi
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .open
    mov r12, rax
    mov edi, r12d
    mov rsi, statbuf
    mov eax, SYS_FSTAT
    syscall
    test rax, rax
    js .open
    mov r13, [statbuf+48]           ; st_size
    cmp r13, 44
    jb .bad
    xor edi, edi
    mov rsi, r13
    mov edx, 1                      ; PROT_READ
    mov r10d, 2                     ; MAP_PRIVATE
    mov r8, r12
    xor r9d, r9d
    mov eax, SYS_MMAP
    syscall
    cmp rax, -4096
    ja .open
    mov rbx, rax
    mov edi, r12d
    mov eax, SYS_CLOSE
    syscall

    cmp dword [rbx], 'RIFF'
    jne .bad
    cmp dword [rbx+8], 'WAVE'
    jne .bad
    mov dword [wav_tag], 0
    mov qword [wav_data], 0
    lea r14, [rbx+12]
    lea r15, [rbx+r13]
.chunk:
    lea rax, [r14+8]
    cmp rax, r15
    ja .walked
    mov eax, [r14]
    mov ecx, [r14+4]
    cmp eax, 'fmt '
    jne .notfmt
    cmp ecx, 16
    jb .bad
    movzx edx, word [r14+8]
    mov [wav_tag], edx
    movzx edx, word [r14+10]
    mov [wav_ch], edx
    mov edx, [r14+12]
    mov [wav_rate], edx
    movzx edx, word [r14+22]
    mov [wav_bits], edx
    cmp dword [wav_tag], 0xFFFE     ; extensible: the real format is in the sub format guid
    jne .next
    cmp ecx, 40
    jb .next
    movzx edx, word [r14+32]
    mov [wav_tag], edx
    jmp .next
.notfmt:
    cmp eax, 'data'
    jne .next
    lea rax, [r14+8]
    mov [wav_data], rax
    mov rdx, r15
    sub rdx, rax
    cmp rcx, rdx
    jbe .fits
    mov rcx, rdx                    ; truncated file, take what's there
.fits:
    mov [wav_bytes], rcx
.next:
    mov ecx, [r14+4]
    lea r14, [r14+rcx+8]
    and ecx, 1
    add r14, rcx                    ; chunks are padded to even sizes
    jmp .chunk
.walked:
    cmp qword [wav_data], 0
    je .bad
    cmp dword [wav_tag], 1
    jne .flt
    cmp dword [wav_bits], 16
    jne .fmt
    mov dword [wav_bps], 2
    jmp .fmt_ok
.flt:
    cmp dword [wav_tag], 3
    jne .fmt
    cmp dword [wav_bits], 32
    jne .fmt
    mov dword [wav_bps], 4
.fmt_ok:
    cmp dword [wav_ch], 0
    je .fmt
    cmp dword [wav_rate], 0
    je .fmt
    mov eax, [wav_ch]
    imul eax, [wav_bps]
    mov ecx, eax
    mov rax, [wav_bytes]
    xor edx, edx
    div rcx
    mov [wav_frames], rax
    test rax, rax
    jz .none

    cvtsi2sd xmm0, dword [wav_rate]
    divsd xmm0, [k_8k]
    movsd [wav_ratio], xmm0

    ; room for frames*8000/rate + a bit
    mov rax, [wav_frames]
    imul rax, rax, 8000
    xor edx, edx
    mov ecx, [wav_rate]
    div rcx
    add rax, 4
    lea rsi, [rax*2]
    xor edi, edi
    mov edx, 3                      ; PROT_READ | PROT_WRITE
    mov r10d, 0x22                  ; MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    mov eax, SYS_MMAP
    syscall
    cmp rax, -4096
    ja .nomem
    mov [wav_out], rax

    xor r12d, r12d                  ; output sample k
.k:
    cvtsi2sd xmm0, r12
    mulsd xmm0, [wav_ratio]
    cvttsd2si r13, xmm0             ; lo
    lea rax, [r12+1]
    cvtsi2sd xmm0, rax
    mulsd xmm0, [wav_ratio]
    cvttsd2si r14, xmm0             ; hi
    cmp r14, r13
    jg .span
    lea r14, [r13+1]                ; going up in rate: just hold the nearest one
.span:
    cmp r14, [wav_frames]
    ja .end
    xorpd xmm1, xmm1
    mov r15, r13
.f:
    mov eax, [wav_ch]
    imul eax, [wav_bps]
    mov rsi, r15
    imul rsi, rax
    add rsi, [wav_data]
    xor ecx, ecx
.c:
    cmp dword [wav_bps], 2
    jne .cf
    movsx eax, word [rsi+rcx*2]
    cvtsi2sd xmm0, eax
    jmp .ca
.cf:
    cvtss2sd xmm0, [rsi+rcx*4]
    mulsd xmm0, [k_s16]
.ca:
    addsd xmm1, xmm0
    inc ecx
    cmp ecx, [wav_ch]
    jb .c
    inc r15
    cmp r15, r14
    jb .f
    mov rax, r14
    sub rax, r13
    imul eax, [wav_ch]
    cvtsi2sd xmm0, rax
    divsd xmm1, xmm0
    maxsd xmm1, [k_s16lo]
    minsd xmm1, [k_s16]
    cvtsd2si eax, xmm1
    mov rdx, [wav_out]
    mov [rdx+r12*2], ax
    inc r12
    jmp .k
.end:
    test r12, r12
    jz .none
    mov rax, [wav_out]
    mov rdx, r12
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.open:
    mov rdi, s_wav_open
    jmp die
.bad:
    mov rdi, s_wav_bad
    jmp die
.fmt:
    mov rdi, s_wav_fmt
    jmp die
.none:
    mov rdi, s_wav_none
    jmp die
.nomem:
    mov rdi, s_nomem
    jmp die
