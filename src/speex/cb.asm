; cb.asm - the innovation: 4 slices of 10 samples, one of 32 fixed shapes each. no sign bit
; and no gain of their own in this mode, the size comes from the frame gain. so all we get
; to pick is the shape, and we pick it against the whole rest of the subframe, not just the
; 10 samples it sits on, because its echo through the filter lands on the later slices too.

section .data
align 8
k_32nd:     dq 0.03125

section .bss
alignb 8
cbv:        resq L
resp:       resq 32*L
innov:      resq L
cb_scale:   resq 1
shapes:     resd 4

section .text

; xmm0 = gain for this subframe. reads imp, eats tgt2, fills innov and shapes
innov_search:
    push rbx
    push r12
    push r13
    mulsd xmm0, [k_32nd]
    movsd [cb_scale], xmm0
    xorpd xmm0, xmm0
    mov ecx, 10
.z:
    movsd [cbv+rcx*8], xmm0
    inc ecx
    cmp ecx, L
    jb .z

    ; every shape through the filter once
    xor ebx, ebx
.r:
    imul r12d, ebx, 10
    xor ecx, ecx
.rj:
    lea eax, [r12+rcx]
    movsx eax, byte [exc_cb+rax]
    cvtsi2sd xmm0, eax
    mulsd xmm0, [cb_scale]
    movsd [cbv+rcx*8], xmm0
    inc ecx
    cmp ecx, 10
    jb .rj
    imul eax, ebx, L*8
    mov rsi, imp
    mov rdi, cbv
    lea rdx, [resp+rax]
    call conv40
    inc ebx
    cmp ebx, 32
    jb .r

    xor r12d, r12d                  ; slice
.sv:
    imul r13d, r12d, 10             ; where it starts
    mov r9d, L
    sub r9d, r13d                   ; how much subframe is left from there
    movsd xmm7, [k_big]
    xor ebx, ebx
    xor edx, edx
.c:
    imul eax, edx, L*8
    lea rsi, [resp+rax]
    xorpd xmm0, xmm0
    xor ecx, ecx
.n:
    lea eax, [r13+rcx]
    movsd xmm1, [tgt2+rax*8]
    subsd xmm1, [rsi+rcx*8]
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    inc ecx
    cmp ecx, r9d
    jb .n
    comisd xmm0, xmm7
    jae .cn
    movsd xmm7, xmm0
    mov ebx, edx
.cn:
    inc edx
    cmp edx, 32
    jb .c

    imul eax, ebx, L*8
    lea rsi, [resp+rax]
    xor ecx, ecx
.t:
    lea eax, [r13+rcx]
    movsd xmm1, [tgt2+rax*8]
    subsd xmm1, [rsi+rcx*8]
    movsd [tgt2+rax*8], xmm1
    inc ecx
    cmp ecx, r9d
    jb .t
    imul edx, ebx, 10
    xor ecx, ecx
.in:
    lea eax, [rdx+rcx]
    movsx eax, byte [exc_cb+rax]
    cvtsi2sd xmm0, eax
    mulsd xmm0, [cb_scale]
    lea eax, [r13+rcx]
    movsd [innov+rax*8], xmm0
    inc ecx
    cmp ecx, 10
    jb .in
    mov [shapes+r12*4], ebx
    inc r12d
    cmp r12d, 4
    jb .sv
    pop r13
    pop r12
    pop rbx
    ret
