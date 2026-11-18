; quant.asm - the low bit-rate lsp quantiser, 18 bits: one 10-wide stage, then two 5-wide
; weighted stages for the leftovers. the quantised lsps are rebuilt exactly the way the
; decoder rebuilds them, so the encoder never works with something the other side can't see.

section .data
align 8
k_256:      dq 256.0
k_004:      dq 0.04
k_div256:   dq 0.0039062        ; the decoder's own idea of 1/256 and 1/512, not quite exact
k_div512:   dq 0.0019531

section .bss
alignb 8
qw:         resq P              ; per lsp weights
qr:         resq P              ; residual being quantised
lsp_ids:    resd 3

section .text

; xmm0 = 0.25*i + 0.25 for i in ecx
lsp_lin:
    cvtsi2sd xmm0, ecx
    mulsd xmm0, [k_quarter]
    addsd xmm0, [k_quarter]
    ret

; rsi = 10 lsps, rdi = 10 quantised lsps out, ids land in lsp_ids
quant_lsp:
    push rbx
    push r12
    push r13
    mov r12, rsi
    mov r13, rdi

    ; weight each lsp by how close its neighbours are: crowded ones are formants, keep them sharp
    xor ecx, ecx
.w:
    test ecx, ecx
    jnz .w1
    movsd xmm0, [r12]
    jmp .w2
.w1:
    movsd xmm0, [r12+rcx*8]
    subsd xmm0, [r12+rcx*8-8]
.w2:
    cmp ecx, P-1
    jne .w3
    movsd xmm1, [k_pi]
    subsd xmm1, [r12+rcx*8]
    jmp .w4
.w3:
    movsd xmm1, [r12+rcx*8+8]
    subsd xmm1, [r12+rcx*8]
.w4:
    minsd xmm0, xmm1
    addsd xmm0, [k_004]
    movsd xmm1, [k_ten]
    divsd xmm1, xmm0
    movsd [qw+rcx*8], xmm1
    inc ecx
    cmp ecx, P
    jb .w

    xor ecx, ecx
.r:
    call lsp_lin
    movsd xmm1, [r12+rcx*8]
    subsd xmm1, xmm0
    mulsd xmm1, [k_256]
    movsd [qr+rcx*8], xmm1
    inc ecx
    cmp ecx, P
    jb .r

    ; stage 1, plain distance
    movsd xmm7, [k_big]
    xor ebx, ebx                    ; best
    xor edx, edx                    ; candidate
.s1:
    xorpd xmm0, xmm0
    imul eax, edx, 10
    xor ecx, ecx
.s1j:
    movsx r8d, byte [lsp_cb1+rax+rcx]
    cvtsi2sd xmm2, r8d
    movsd xmm1, [qr+rcx*8]
    subsd xmm1, xmm2
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    inc ecx
    cmp ecx, P
    jb .s1j
    comisd xmm0, xmm7
    jae .s1n
    movsd xmm7, xmm0
    mov ebx, edx
.s1n:
    inc edx
    cmp edx, 64
    jb .s1
    mov [lsp_ids], ebx
    imul eax, ebx, 10
    xor ecx, ecx
.s1r:
    movsx r8d, byte [lsp_cb1+rax+rcx]
    cvtsi2sd xmm2, r8d
    movsd xmm1, [qr+rcx*8]
    subsd xmm1, xmm2
    mulsd xmm1, [k_two]             ; now in 1/512 rad
    movsd [qr+rcx*8], xmm1
    inc ecx
    cmp ecx, P
    jb .s1r

    ; stage 2, low and high halves, weighted
    mov rsi, lsp_cb_lo
    xor r9d, r9d
    call .stage2
    mov [lsp_ids+4], ebx
    mov rsi, lsp_cb_hi
    mov r9d, 5
    call .stage2
    mov [lsp_ids+8], ebx

    ; rebuild like the decoder does
    xor ecx, ecx
.q:
    call lsp_lin
    imul eax, [lsp_ids], 10
    movsx r8d, byte [lsp_cb1+rax+rcx]
    cvtsi2sd xmm1, r8d
    mulsd xmm1, [k_div256]
    addsd xmm0, xmm1
    movsd [r13+rcx*8], xmm0
    inc ecx
    cmp ecx, P
    jb .q
    xor ecx, ecx
.q2:
    imul eax, [lsp_ids+4], 5
    movsx r8d, byte [lsp_cb_lo+rax+rcx]
    cvtsi2sd xmm1, r8d
    mulsd xmm1, [k_div512]
    addsd xmm1, [r13+rcx*8]
    movsd [r13+rcx*8], xmm1
    imul eax, [lsp_ids+8], 5
    movsx r8d, byte [lsp_cb_hi+rax+rcx]
    cvtsi2sd xmm1, r8d
    mulsd xmm1, [k_div512]
    addsd xmm1, [r13+rcx*8+40]
    movsd [r13+rcx*8+40], xmm1
    inc ecx
    cmp ecx, 5
    jb .q2
    pop r13
    pop r12
    pop rbx
    ret

; rsi = 64 x 5 codebook, r9 = first lsp of the half -> ebx = best entry
.stage2:
    movsd xmm7, [k_big]
    xor ebx, ebx
    xor edx, edx
.s2:
    xorpd xmm0, xmm0
    imul eax, edx, 5
    lea r11, [rsi+rax]
    xor ecx, ecx
.s2j:
    movsx r8d, byte [r11+rcx]
    cvtsi2sd xmm2, r8d
    lea r10, [r9+rcx]
    movsd xmm1, [qr+r10*8]
    subsd xmm1, xmm2
    movsd xmm3, [qw+r10*8]
    mulsd xmm3, xmm1
    mulsd xmm3, xmm1
    addsd xmm0, xmm3
    inc ecx
    cmp ecx, 5
    jb .s2j
    comisd xmm0, xmm7
    jae .s2n
    movsd xmm7, xmm0
    mov ebx, edx
.s2n:
    inc edx
    cmp edx, 64
    jb .s2
    ret
