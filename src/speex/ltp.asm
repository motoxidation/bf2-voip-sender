; ltp.asm - pitch. cheap open loop guesses on the weighted speech, then the real 3-tap
; search against the excitation the decoder actually has, through the weighted synthesis
; filter. 7 bits of lag (17..144) and 5 bits picking a gain triple.

section .data
align 8
k_64th:     dq 0.015625

section .bss
alignb 8
cand_s:     resq NCAND
cand_t:     resd NCAND
ncand:      resd 1
vecs:       resq 3*L            ; what lags T-1, T, T+1 pull out of the history
ys:         resq 3*L            ; the same after the weighted synthesis filter
pcc:        resq 3
prr:        resq 9
gains:      resq 3
best_err:   resq 1
best_t:     resd 1
best_gi:    resd 1
pl_t:       resd 1

section .text

; best NCAND lags by normalised correlation of the weighted speech with itself
ol_pitch:
    push rbx
    push r12
    mov dword [ncand], 0
    mov r12d, [sf_j0]
    mov ebx, PMIN
.t:
    xorpd xmm0, xmm0                ; correlation
    xorpd xmm1, xmm1                ; energy
    xor ecx, ecx
.n:
    lea eax, [r12+rcx]
    mov edx, eax
    sub edx, ebx
    movsd xmm2, [swb+rdx*8]
    movsd xmm3, [swb+rax*8]
    mulsd xmm3, xmm2
    addsd xmm0, xmm3
    mulsd xmm2, xmm2
    addsd xmm1, xmm2
    inc ecx
    cmp ecx, L
    jb .n
    xorpd xmm2, xmm2
    comisd xmm0, xmm2
    jbe .skip
    comisd xmm1, xmm2
    jbe .skip
    movsd xmm2, xmm0
    mulsd xmm2, xmm0
    divsd xmm2, xmm1
    ; keep the list sorted, a tie goes to the longer lag
    xor ecx, ecx
.f:
    cmp ecx, [ncand]
    jae .at
    comisd xmm2, [cand_s+rcx*8]
    jae .at
    inc ecx
    jmp .f
.at:
    cmp ecx, NCAND
    jae .skip
    mov eax, [ncand]
    cmp eax, NCAND-1
    jbe .sh
    mov eax, NCAND-1
.sh:
    cmp eax, ecx
    jbe .put
    movsd xmm3, [cand_s+rax*8-8]
    movsd [cand_s+rax*8], xmm3
    mov edx, [cand_t+rax*4-4]
    mov [cand_t+rax*4], edx
    dec eax
    jmp .sh
.put:
    movsd [cand_s+rcx*8], xmm2
    mov [cand_t+rcx*4], ebx
    cmp dword [ncand], NCAND
    jae .skip
    inc dword [ncand]
.skip:
    inc ebx
    cmp ebx, PMAX
    jbe .t
    cmp dword [ncand], 0
    jne .done
    mov dword [cand_t], PMIN        ; silence: nothing correlates, any lag will do
    mov dword [ncand], 1
.done:
    pop r12
    pop rbx
    ret

; eax = lag. fills vecs the way the decoder's pitch_unquant_3tap reads the history:
; vecs[2-i] uses pp = T+1-i, and a lag shorter than the subframe repeats from one more
; period back, not from what it just made
build_vecs:
    push rbx
    push r12
    push r13
    mov r12d, eax
    xor ebx, ebx
.i:
    lea r13d, [r12+1]
    sub r13d, ebx                   ; pp
    mov eax, 2
    sub eax, ebx
    imul eax, eax, L*8
    lea rdi, [vecs+rax]
    xorpd xmm0, xmm0
    xor ecx, ecx
.z:
    movsd [rdi+rcx*8], xmm0
    inc ecx
    cmp ecx, L
    jb .z
    mov edx, L
    cmp r13d, edx
    cmovb edx, r13d                 ; first stretch: one period back
    mov r8d, [sf_e0]
    xor ecx, ecx
.a:
    cmp ecx, edx
    jae .b
    lea eax, [r8+rcx]
    sub eax, r13d
    movsd xmm0, [excb+rax*8]
    movsd [rdi+rcx*8], xmm0
    inc ecx
    jmp .a
.b:
    mov r9d, r13d
    add r9d, r12d
    cmp r9d, L
    jbe .c
    mov r9d, L
.c:
    cmp ecx, r9d                    ; second stretch: two periods back
    jae .nx
    lea eax, [r8+rcx]
    sub eax, r13d
    sub eax, r12d
    movsd xmm0, [excb+rax*8]
    movsd [rdi+rcx*8], xmm0
    inc ecx
    jmp .c
.nx:
    inc ebx
    cmp ebx, 3
    jb .i
    pop r13
    pop r12
    pop rbx
    ret

; vecs -> ys, and the correlations the gain search needs
filt_vecs:
    push rbx
    xor ebx, ebx
.f:
    imul eax, ebx, L*8
    mov rsi, imp
    lea rdi, [vecs+rax]
    lea rdx, [ys+rax]
    call conv40
    imul eax, ebx, L*8
    mov rsi, tgt
    lea rdi, [ys+rax]
    mov ecx, L
    call dot
    movsd [pcc+rbx*8], xmm0
    inc ebx
    cmp ebx, 3
    jb .f
    xor ebx, ebx
.r:
    mov eax, ebx
    xor edx, edx
    mov ecx, 3
    div ecx                         ; eax = k, edx = l
    imul eax, eax, L*8
    imul edx, edx, L*8
    lea rsi, [ys+rax]
    lea rdi, [ys+rdx]
    mov ecx, L
    call dot
    movsd [prr+rbx*8], xmm0
    inc ebx
    cmp ebx, 9
    jb .r
    pop rbx
    ret

; ebx = gain entry -> gains
load_gains:
    xor ecx, ecx
.g:
    movsx eax, byte [gain_cb+rbx*4+rcx]
    cvtsi2sd xmm0, eax
    mulsd xmm0, [k_64th]
    addsd xmm0, [k_half]
    movsd [gains+rcx*8], xmm0
    inc ecx
    cmp ecx, 3
    jb .g
    ret

; ebx = gain entry -> xmm0 = |t - sum g y|^2 minus the constant |t|^2
gain_err:
    call load_gains
    xorpd xmm0, xmm0
    xor ecx, ecx
.k:
    movsd xmm1, [gains+rcx*8]
    movsd xmm2, xmm1
    mulsd xmm2, xmm1
    imul eax, ecx, 4                ; diagonal of the 3x3
    mulsd xmm2, [prr+rax*8]
    movsd xmm3, xmm1
    addsd xmm3, xmm1
    mulsd xmm3, [pcc+rcx*8]
    subsd xmm2, xmm3
    addsd xmm0, xmm2
    lea edx, [rcx+1]
.l:
    cmp edx, 3
    jae .kn
    movsd xmm2, xmm1
    addsd xmm2, xmm1
    mulsd xmm2, [gains+rdx*8]
    imul eax, ecx, 3
    add eax, edx
    mulsd xmm2, [prr+rax*8]
    addsd xmm0, xmm2
    inc edx
    jmp .l
.kn:
    inc ecx
    cmp ecx, 3
    jb .k
    ret

; tries every candidate lag with every gain triple, keeps the best,
; then leaves pexc (the pitch part of the excitation) and tgt2 (what is left to explain)
pitch_search:
    push rbx
    push r12
    movsd xmm0, [k_big]
    movsd [best_err], xmm0
    mov dword [best_t], PMIN
    mov dword [best_gi], 0
    xor r12d, r12d
.c:
    cmp r12d, [ncand]
    jae .fin
    mov eax, [cand_t+r12*4]
    mov [pl_t], eax
    call build_vecs
    call filt_vecs
    xor ebx, ebx
.g:
    call gain_err
    comisd xmm0, [best_err]
    jae .gn
    movsd [best_err], xmm0
    mov eax, [pl_t]
    mov [best_t], eax
    mov [best_gi], ebx
.gn:
    inc ebx
    cmp ebx, 32
    jb .g
    inc r12d
    jmp .c
.fin:
    mov eax, [best_t]
    call build_vecs
    call filt_vecs
    mov ebx, [best_gi]
    call load_gains
    xor ecx, ecx
.p:
    movsd xmm0, [gains]
    mulsd xmm0, [vecs+rcx*8]
    movsd xmm1, [gains+8]
    mulsd xmm1, [vecs+L*8+rcx*8]
    addsd xmm0, xmm1
    movsd xmm1, [gains+16]
    mulsd xmm1, [vecs+2*L*8+rcx*8]
    addsd xmm0, xmm1
    movsd [pexc+rcx*8], xmm0
    movsd xmm0, [gains]
    mulsd xmm0, [ys+rcx*8]
    movsd xmm1, [gains+8]
    mulsd xmm1, [ys+L*8+rcx*8]
    addsd xmm0, xmm1
    movsd xmm1, [gains+16]
    mulsd xmm1, [ys+2*L*8+rcx*8]
    addsd xmm0, xmm1
    movsd xmm1, [tgt+rcx*8]
    subsd xmm1, xmm0
    movsd [tgt2+rcx*8], xmm1
    inc ecx
    cmp ecx, L
    jb .p
    pop r12
    pop rbx
    ret
