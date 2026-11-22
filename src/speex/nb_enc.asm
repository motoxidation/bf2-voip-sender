; nb_enc.asm - speex narrowband, submode 3: 8 kbps, 160 bits a frame, 20 bytes
;
;   wideband 1 | submode 4 | lsp 6 6 6 | frame gain 5 |
;   4 x ( pitch 7 | pitch gain 5 | subframe gain 1 | shape 5 5 5 5 )
;
; doubles all the way. we keep our own copy of what the decoder rebuilds (excitation history
; and its synthesis filter), so every closed loop search runs against what the other end
; will actually hear.
;
; each frame runs the subframes twice. the frame gain goes out before the subframes, but
; how much innovation they want is only known after the pitch search. so pass 1 measures,
; we pick the gain, roll the state back, and pass 2 does it for real.

ST_Q equ EXH+N+3*P                  ; qwords of decoder mirror between st_begin and st_save

section .data
align 8
k_hp:       dq 0.95                 ; dc blocker
k_bound:    dq 0.87798              ; subframe gain: below this pick the low step
k_scal1:    dq 0.70469, 1.05127     ; the two subframe gain steps
k_gmid:     dq 0.8607               ; their geometric middle
k_3p5:      dq 3.5                  ; frame gain is exp(q/3.5)
k_tiny:     dq 1e-9
k_L:        dq 40.0

section .bss
alignb 8
xbuf:       resq WIN
hp_x:       resq 1
hp_y:       resq 1
swb:        resq SWLEN
lsp_cur:    resq P
lsp_q:      resq P
lsp_old:    resq P
lsp_qold:   resq P
ipl:        resq P
aks:        resq 4*(P+1)            ; per subframe lpc, unquantised (for weighting)
aqs:        resq 4*(P+1)            ; and quantised (what the decoder filters with)

st_begin:
excb:       resq EXH+N
sh:         resq P                  ; last decoded samples
shw:        resq P                  ; same, weighted
memsp:      resq P                  ; decoder's synthesis filter state
st_save:    resq ST_Q

bw1:        resq P+1
bw2:        resq P+1
tgt:        resq L
tgt2:       resq L
imp:        resq L
pexc:       resq L
hs_t:       resq P+L
hw_t:       resq P+L
memz:       resq P
eners:      resq 4
olg:        resq 1
ener:       resq 1
cur_ak:     resq 1
cur_aq:     resq 1
have_lsp:   resd 1
have_old:   resd 1
pass1:      resd 1
ol_qe:      resd 1
sf_s:       resd 1
sf_e0:      resd 1                  ; subframe start in excb
sf_j0:      resd 1                  ; in swb
sf_x0:      resd 1                  ; in xbuf
sub_par:    resd 4*7                ; pitch, gain entry, subframe gain, 4 shapes
bitpos:     resd 1
bitbuf:     resb 20

section .text

enc_init:
    jmp lpc_init

; rsi = 160 samples of s16, rdi = 20 bytes out
enc_frame:
    push rbx
    push r12
    push r13
    mov r12, rsi
    mov r13, rdi

    mov rsi, xbuf+N*8
    mov rdi, xbuf
    mov ecx, WIN-N
    rep movsq
    xor ebx, ebx
.hp:
    movsx eax, word [r12+rbx*2]
    cvtsi2sd xmm0, eax
    movsd xmm1, xmm0
    subsd xmm1, [hp_x]
    movsd xmm2, [k_hp]
    mulsd xmm2, [hp_y]
    addsd xmm1, xmm2
    movsd [hp_x], xmm0
    movsd [hp_y], xmm1
    movsd [xbuf+(WIN-N)*8+rbx*8], xmm1
    inc ebx
    cmp ebx, N
    jb .hp

    call lpc_analyse
    call lpc_to_lsp
    test eax, eax
    jz .keep
    mov rsi, lsp_new
    mov rdi, lsp_cur
    mov ecx, P
    rep movsq
    mov dword [have_lsp], 1
    jmp .quant
.keep:
    cmp dword [have_lsp], 0         ; no clean roots: reuse last frame's, or flat if there's none
    jne .quant
    xor ecx, ecx
.flat:
    call lsp_lin
    movsd [lsp_cur+rcx*8], xmm0
    inc ecx
    cmp ecx, P
    jb .flat
    mov dword [have_lsp], 1
.quant:
    mov rsi, lsp_cur
    mov rdi, lsp_q
    call quant_lsp
    cmp dword [have_old], 0
    jne .ip
    mov rsi, lsp_q
    mov rdi, lsp_qold
    mov ecx, P
    rep movsq
    mov rsi, lsp_cur
    mov rdi, lsp_old
    mov ecx, P
    rep movsq
    mov dword [have_old], 1
.ip:
    xor ebx, ebx
.ips:
    mov rsi, lsp_old
    mov rdi, lsp_cur
    mov edx, ebx
    xor ecx, ecx
    mov r8, ipl
    call lsp_interp
    imul eax, ebx, (P+1)*8
    lea rdi, [aks+rax]
    mov rsi, ipl
    call lsp_to_lpc
    mov rsi, lsp_qold
    mov rdi, lsp_q
    mov edx, ebx
    mov ecx, 1
    mov r8, ipl
    call lsp_interp
    imul eax, ebx, (P+1)*8
    lea rdi, [aqs+rax]
    mov rsi, ipl
    call lsp_to_lpc
    inc ebx
    cmp ebx, 4
    jb .ips

    mov rsi, swb+N*8
    mov rdi, swb
    mov ecx, SWLEN-N
    rep movsq
    call weigh_speech

    mov rsi, st_begin
    mov rdi, st_save
    mov ecx, ST_Q
    rep movsq
    mov dword [pass1], 1
    call subframes
    mov rsi, st_save
    mov rdi, st_begin
    mov ecx, ST_Q
    rep movsq

    ; frame gain from what pass 1 wanted
    xorpd xmm0, xmm0
    xor ecx, ecx
.e:
    movsd xmm1, [eners+rcx*8]
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    inc ecx
    cmp ecx, 4
    jb .e
    divsd xmm0, [k_four]
    sqrtsd xmm0, xmm0
    maxsd xmm0, [k_tiny]
    divsd xmm0, [k_gmid]
    call f_ln
    mulsd xmm0, [k_3p5]
    addsd xmm0, [k_half]
    call f_floor
    test rax, rax
    jns .q0
    xor eax, eax
.q0:
    cmp rax, 31
    jle .q1
    mov eax, 31
.q1:
    mov [ol_qe], eax
    cvtsi2sd xmm0, eax
    divsd xmm0, [k_3p5]
    call f_exp
    movsd [olg], xmm0
    mov dword [pass1], 0
    call subframes

    ; pack it
    xor eax, eax
    mov [bitpos], eax
    mov [bitbuf], rax
    mov [bitbuf+8], rax
    mov [bitbuf+16], eax
    xor edi, edi
    mov esi, 1
    call bits_put                   ; not wideband
    mov edi, 3
    mov esi, 4
    call bits_put                   ; submode 3
    mov edi, [lsp_ids]
    mov esi, 6
    call bits_put
    mov edi, [lsp_ids+4]
    mov esi, 6
    call bits_put
    mov edi, [lsp_ids+8]
    mov esi, 6
    call bits_put
    mov edi, [ol_qe]
    mov esi, 5
    call bits_put
    xor ebx, ebx
.pk:
    imul r12d, ebx, 7*4
    mov edi, [sub_par+r12]
    sub edi, PMIN
    mov esi, 7
    call bits_put
    mov edi, [sub_par+r12+4]
    mov esi, 5
    call bits_put
    mov edi, [sub_par+r12+8]
    mov esi, 1
    call bits_put
    mov edi, [sub_par+r12+12]
    mov esi, 5
    call bits_put
    mov edi, [sub_par+r12+16]
    mov esi, 5
    call bits_put
    mov edi, [sub_par+r12+20]
    mov esi, 5
    call bits_put
    mov edi, [sub_par+r12+24]
    mov esi, 5
    call bits_put
    inc ebx
    cmp ebx, 4
    jb .pk
    mov rsi, bitbuf
    mov rdi, r13
    mov ecx, 20
    rep movsb

    mov rsi, lsp_cur
    mov rdi, lsp_old
    mov ecx, P
    rep movsq
    mov rsi, lsp_q
    mov rdi, lsp_qold
    mov ecx, P
    rep movsq
    mov rsi, excb+N*8
    mov rdi, excb
    mov ecx, EXH
    rep movsq
    xor eax, eax
    mov ecx, N
    rep stosq
    pop r13
    pop r12
    pop rbx
    ret

; edi = value, esi = bit count, msb first
bits_put:
    dec esi
    js .d
    mov eax, edi
    mov ecx, esi
    shr eax, cl
    test eax, 1
    jz .z
    mov edx, [bitpos]
    mov ecx, edx
    shr edx, 3
    and ecx, 7
    mov al, 0x80
    shr al, cl
    or [bitbuf+rdx], al
.z:
    inc dword [bitpos]
    jmp bits_put
.d:
    ret

; the input through W(z) = A(z/0.9) / A(z/0.6), with each subframe's own lpc
weigh_speech:
    push rbx
    xor ebx, ebx
.n:
    mov eax, ebx
    xor edx, edx
    mov ecx, L
    div ecx
    imul eax, eax, (P+1)*8
    lea rsi, [aks+rax]
    lea r8d, [rbx+FRM]
    movsd xmm0, [xbuf+r8*8]
    mov ecx, 1
.k1:
    movsd xmm1, [rsi+rcx*8]
    mulsd xmm1, [g1tab+rcx*8]
    mov eax, r8d
    sub eax, ecx
    mulsd xmm1, [xbuf+rax*8]
    addsd xmm0, xmm1
    inc ecx
    cmp ecx, P
    jbe .k1
    lea r9d, [rbx+SWBASE]
    mov ecx, 1
.k2:
    movsd xmm1, [rsi+rcx*8]
    mulsd xmm1, [g2tab+rcx*8]
    mov eax, r9d
    sub eax, ecx
    mulsd xmm1, [swb+rax*8]
    subsd xmm0, xmm1
    inc ecx
    cmp ecx, P
    jbe .k2
    movsd [swb+r9*8], xmm0
    inc ebx
    cmp ebx, N
    jb .n
    pop rbx
    ret

subframes:
    push rbx
    xor ebx, ebx
.s:
    mov [sf_s], ebx
    imul eax, ebx, L
    lea ecx, [rax+EXH]
    mov [sf_e0], ecx
    lea ecx, [rax+SWBASE]
    mov [sf_j0], ecx
    lea ecx, [rax+FRM]
    mov [sf_x0], ecx
    imul eax, ebx, (P+1)*8
    lea rcx, [aks+rax]
    mov [cur_ak], rcx
    lea rcx, [aqs+rax]
    mov [cur_aq], rcx
    call sf_weights
    call sf_target
    call sf_impulse
    call ol_pitch
    call pitch_search
    call sf_energy
    movsd xmm0, [ener]
    call innov_search
    call sf_update
    inc ebx
    cmp ebx, 4
    jb .s
    pop rbx
    ret

sf_weights:
    mov rsi, [cur_ak]
    xor ecx, ecx
.k:
    movsd xmm0, [rsi+rcx*8]
    movsd xmm1, xmm0
    mulsd xmm0, [g1tab+rcx*8]
    mulsd xmm1, [g2tab+rcx*8]
    movsd [bw1+rcx*8], xmm0
    movsd [bw2+rcx*8], xmm1
    inc ecx
    cmp ecx, P
    jbe .k
    ret

; r12 = n, xmm0 = synthesised sample. runs it through W(z) using hs_t/hw_t history,
; appends both -> xmm0 = weighted sample
wsynth:
    movsd xmm1, xmm0
    mov ecx, 1
.k:
    lea eax, [r12+P]
    sub eax, ecx
    movsd xmm2, [bw1+rcx*8]
    mulsd xmm2, [hs_t+rax*8]
    movsd xmm3, [bw2+rcx*8]
    mulsd xmm3, [hw_t+rax*8]
    subsd xmm2, xmm3
    addsd xmm1, xmm2
    inc ecx
    cmp ecx, P
    jbe .k
    lea eax, [r12+P]
    movsd [hs_t+rax*8], xmm0
    movsd [hw_t+rax*8], xmm1
    movsd xmm0, xmm1
    ret

; rsi/rdi pairs for the 10 sample history copies
hist_in:
    mov rsi, sh
    mov rdi, hs_t
    mov ecx, P
    rep movsq
    mov rsi, shw
    mov rdi, hw_t
    mov ecx, P
    rep movsq
    ret

; target = weighted speech minus what the filters ring out on their own
sf_target:
    push r12
    call hist_in
    mov rsi, memsp
    mov rdi, memz
    mov ecx, P
    rep movsq
    xor r12d, r12d
.n:
    xorpd xmm0, xmm0
    mov rsi, [cur_aq]
    mov rdi, memz
    call iir_step
    call wsynth
    mov eax, [sf_j0]
    add eax, r12d
    movsd xmm1, [swb+rax*8]
    subsd xmm1, xmm0
    movsd [tgt+r12*8], xmm1
    inc r12d
    cmp r12d, L
    jb .n
    pop r12
    ret

; impulse response of the weighted synthesis filter, from rest
sf_impulse:
    push r12
    xorpd xmm0, xmm0
    xor ecx, ecx
.z:
    movsd [hs_t+rcx*8], xmm0
    movsd [hw_t+rcx*8], xmm0
    inc ecx
    cmp ecx, P
    jb .z
    mov rsi, [cur_aq]
    xor r12d, r12d
.n:
    xorpd xmm0, xmm0
    test r12d, r12d
    jnz .nz
    movsd xmm0, [k_one]
.nz:
    mov ecx, 1
.k:
    lea eax, [r12+P]
    sub eax, ecx
    movsd xmm1, [rsi+rcx*8]
    mulsd xmm1, [hs_t+rax*8]
    subsd xmm0, xmm1
    inc ecx
    cmp ecx, P
    jbe .k
    call wsynth
    movsd [imp+r12*8], xmm0
    inc r12d
    cmp r12d, L
    jb .n
    pop r12
    ret

; how loud the innovation needs to be: rms of the real residual minus the pitch part
sf_energy:
    mov rsi, [cur_ak]
    mov r8d, [sf_x0]
    xorpd xmm4, xmm4
    xor edx, edx
.n:
    lea r9d, [r8+rdx]
    movsd xmm0, [xbuf+r9*8]
    mov ecx, 1
.k:
    mov eax, r9d
    sub eax, ecx
    movsd xmm1, [rsi+rcx*8]
    mulsd xmm1, [xbuf+rax*8]
    addsd xmm0, xmm1
    inc ecx
    cmp ecx, P
    jbe .k
    subsd xmm0, [pexc+rdx*8]
    mulsd xmm0, xmm0
    addsd xmm4, xmm0
    inc edx
    cmp edx, L
    jb .n
    divsd xmm4, [k_L]
    sqrtsd xmm4, xmm4
    mov eax, [sf_s]
    movsd [eners+rax*8], xmm4
    imul eax, eax, 7*4
    cmp dword [pass1], 0
    je .real
    movsd [ener], xmm4
    mov dword [sub_par+rax+8], 0
    ret
.real:
    movsd xmm0, xmm4
    divsd xmm0, [olg]
    xor ecx, ecx
    comisd xmm0, [k_bound]
    jb .lo
    mov ecx, 1
.lo:
    mov [sub_par+rax+8], ecx
    movsd xmm0, [olg]
    mulsd xmm0, [k_scal1+rcx*8]
    movsd [ener], xmm0
    ret

; excitation = pitch + innovation, then run it through the decoder's filter for real
sf_update:
    push r12
    mov r8d, [sf_e0]
    xor ecx, ecx
.e:
    movsd xmm0, [pexc+rcx*8]
    addsd xmm0, [innov+rcx*8]
    lea eax, [r8+rcx]
    movsd [excb+rax*8], xmm0
    inc ecx
    cmp ecx, L
    jb .e
    call hist_in
    xor r12d, r12d
.n:
    mov eax, [sf_e0]
    add eax, r12d
    movsd xmm0, [excb+rax*8]
    mov rsi, [cur_aq]
    mov rdi, memsp
    call iir_step
    call wsynth
    inc r12d
    cmp r12d, L
    jb .n
    mov rsi, hs_t+L*8
    mov rdi, sh
    mov ecx, P
    rep movsq
    mov rsi, hw_t+L*8
    mov rdi, shw
    mov ecx, P
    rep movsq
    mov eax, [sf_s]
    imul eax, eax, 7*4
    mov ecx, [best_t]
    mov [sub_par+rax], ecx
    mov ecx, [best_gi]
    mov [sub_par+rax+4], ecx
    mov ecx, [shapes]
    mov [sub_par+rax+12], ecx
    mov ecx, [shapes+4]
    mov [sub_par+rax+16], ecx
    mov ecx, [shapes+8]
    mov [sub_par+rax+20], ecx
    mov ecx, [shapes+12]
    mov [sub_par+rax+24], ecx
    pop r12
    ret
