; filt.asm - the three little loops everything else is built from

section .text

; rsi = h, rdi = v, rdx = y. y = h * v over one subframe, the tail just falls off
conv40:
    xor ecx, ecx
.n:
    xorpd xmm0, xmm0
    xor eax, eax
.k:
    mov r8, rcx
    sub r8, rax
    movsd xmm1, [rsi+rax*8]
    mulsd xmm1, [rdi+r8*8]
    addsd xmm0, xmm1
    inc eax
    cmp eax, ecx
    jbe .k
    movsd [rdx+rcx*8], xmm0
    inc ecx
    cmp ecx, L
    jb .n
    ret

; rsi = a, rdi = b, ecx = length -> xmm0
dot:
    xorpd xmm0, xmm0
    xor eax, eax
    test ecx, ecx
    jz .d
.l:
    movsd xmm1, [rsi+rax*8]
    mulsd xmm1, [rdi+rax*8]
    addsd xmm0, xmm1
    inc eax
    cmp eax, ecx
    jb .l
.d:
    ret

; one sample through 1/A(z), done exactly like the decoder's iir_mem16 (transposed form).
; this matters: when the filter changes between subframes the state carries over
; differently than "the last 10 outputs" would, and the decoder drifts away from us.
; xmm0 = in, rsi = a[0..10], rdi = 10 doubles of state -> xmm0 = out. eats xmm1, xmm2, ecx
iir_step:
    addsd xmm0, [rdi]
    xor ecx, ecx
.j:
    movsd xmm1, [rsi+rcx*8+8]
    mulsd xmm1, xmm0
    movsd xmm2, [rdi+rcx*8+8]
    subsd xmm2, xmm1
    movsd [rdi+rcx*8], xmm2
    inc ecx
    cmp ecx, P-1
    jb .j
    movsd xmm1, [rsi+P*8]
    xorpd xmm1, [k_sign]
    mulsd xmm1, xmm0
    movsd [rdi+(P-1)*8], xmm1
    ret
