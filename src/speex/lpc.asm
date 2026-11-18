; lpc.asm - analysis window, autocorrelation, levinson, and lpc <-> lsp
;
; A(z) = 1 + a1 z^-1 + ... + a10 z^-10, same sign as the speex decoder wants it.
; lsps are angles in radians, the even ones belong to P(z), the odd ones to Q(z).

section .data
align 8
k_054:      dq 0.54
k_046:      dq 0.46
k_200:      dq 200.0
k_40:       dq 40.0
k_grid:     dq 512.0
k_60:       dq 60.0
k_8000:     dq 8000.0
k_g1:       dq 0.9          ; perceptual weighting, numerator
k_g2:       dq 0.6          ; and denominator
k_ac0:      dq 1.0001       ; white noise correction, keeps levinson sane on pure tones
k_margin:   dq 0.002        ; minimum lsp spacing, the decoder enforces the same
k_pimarg:   dq 3.139592653589793

section .bss
alignb 8
window:     resq WIN
lagwin:     resq P+1
cosgrid:    resq GRID+1
g1tab:      resq P+1
g2tab:      resq P+1
wx:         resq WIN
acr:        resq P+1
lpc_a:      resq P+1
lev_tmp:    resq P+1
lsp_new:    resq P
cheb_p:     resq 6
cheb_q:     resq 6
roots_p:    resq 8
roots_q:    resq 8
poly_p:     resq 12
poly_q:     resq 12
poly_new:   resq 14
fr_prev:    resq 1
fr_cur:     resq 1
fr_lo:      resq 1
fr_hi:      resq 1
fr_flo:     resq 1

section .text

; window, lag window, root search grid, gamma powers. once at startup
lpc_init:
    xor ecx, ecx
.win:
    cvtsi2sd xmm0, ecx
    cmp ecx, 200
    jae .fall
    mulsd xmm0, [k_pi]              ; rising half of a hamming over 200 samples
    divsd xmm0, [k_200]
    call f_cos
    mulsd xmm0, [k_046]
    movsd xmm1, [k_054]
    subsd xmm1, xmm0
    movsd xmm0, xmm1
    jmp .put
.fall:
    mov eax, ecx                    ; then a quick quarter cosine down over the lookahead
    sub eax, 200
    cvtsi2sd xmm0, eax
    movsd xmm1, [k_half]
    mulsd xmm1, [k_pi]
    mulsd xmm0, xmm1
    divsd xmm0, [k_40]
    call f_cos
.put:
    movsd [window+rcx*8], xmm0
    inc ecx
    cmp ecx, WIN
    jb .win

    xor ecx, ecx
.grid:
    cvtsi2sd xmm0, ecx
    mulsd xmm0, [k_pi]
    divsd xmm0, [k_grid]
    call f_cos
    movsd [cosgrid+rcx*8], xmm0
    inc ecx
    cmp ecx, GRID
    jbe .grid

    ; gaussian lag window, 60 Hz wide
    xor ecx, ecx
.lag:
    movsd xmm0, [k_two]
    mulsd xmm0, [k_pi]
    mulsd xmm0, [k_60]
    cvtsi2sd xmm1, ecx
    mulsd xmm0, xmm1
    divsd xmm0, [k_8000]
    mulsd xmm0, xmm0
    mulsd xmm0, [k_mhalf]
    call f_exp
    movsd [lagwin+rcx*8], xmm0
    inc ecx
    cmp ecx, P
    jbe .lag

    movsd xmm0, [k_one]
    movsd xmm1, xmm0
    xor ecx, ecx
.gam:
    movsd [g1tab+rcx*8], xmm0
    movsd [g2tab+rcx*8], xmm1
    mulsd xmm0, [k_g1]
    mulsd xmm1, [k_g2]
    inc ecx
    cmp ecx, P
    jbe .gam
    ret

; xbuf -> lpc_a
lpc_analyse:
    xor ecx, ecx
.w:
    movsd xmm0, [xbuf+rcx*8]
    mulsd xmm0, [window+rcx*8]
    movsd [wx+rcx*8], xmm0
    inc ecx
    cmp ecx, WIN
    jb .w

    xor edx, edx                    ; lag k
.k:
    xorpd xmm0, xmm0
    mov ecx, edx
.n:
    mov rax, rcx
    sub rax, rdx
    movsd xmm1, [wx+rcx*8]
    mulsd xmm1, [wx+rax*8]
    addsd xmm0, xmm1
    inc ecx
    cmp ecx, WIN
    jb .n
    mulsd xmm0, [lagwin+rdx*8]
    movsd [acr+rdx*8], xmm0
    inc edx
    cmp edx, P
    jbe .k
    movsd xmm0, [acr]
    mulsd xmm0, [k_ac0]
    addsd xmm0, [k_ten]             ; and a floor so silence doesn't divide by zero
    movsd [acr], xmm0

    ; levinson-durbin
    movsd xmm0, [k_one]
    movsd [lpc_a], xmm0
    xorpd xmm0, xmm0
    mov ecx, 1
.z:
    movsd [lpc_a+rcx*8], xmm0
    inc ecx
    cmp ecx, P
    jbe .z
    movsd xmm7, [acr]               ; prediction error
    mov r8d, 1
.li:
    movsd xmm0, [acr+r8*8]
    mov ecx, 1
.lj:
    cmp ecx, r8d
    jae .ljd
    mov rax, r8
    sub rax, rcx
    movsd xmm1, [lpc_a+rcx*8]
    mulsd xmm1, [acr+rax*8]
    addsd xmm0, xmm1
    inc ecx
    jmp .lj
.ljd:
    xorpd xmm0, [k_sign]
    divsd xmm0, xmm7                ; reflection coefficient
    mov ecx, 1
.ln:
    cmp ecx, r8d
    jae .lnd
    mov rax, r8
    sub rax, rcx
    movsd xmm1, [lpc_a+rax*8]
    mulsd xmm1, xmm0
    addsd xmm1, [lpc_a+rcx*8]
    movsd [lev_tmp+rcx*8], xmm1
    inc ecx
    jmp .ln
.lnd:
    mov ecx, 1
.lc:
    cmp ecx, r8d
    jae .lcd
    movsd xmm1, [lev_tmp+rcx*8]
    movsd [lpc_a+rcx*8], xmm1
    inc ecx
    jmp .lc
.lcd:
    movsd [lpc_a+r8*8], xmm0
    mulsd xmm0, xmm0
    movsd xmm1, [k_one]
    subsd xmm1, xmm0
    mulsd xmm7, xmm1
    inc r8d
    cmp r8d, P
    jbe .li
    ret

; rsi = g[0..5] of a symmetric degree 10 polynomial, xmm0 = cos(w)
; -> xmm0 = g5 + 2 sum g[5-m] T_m(x). eats xmm1-5, eax, ecx
cheb:
    movsd xmm1, [k_one]             ; T(m-1)
    movsd xmm2, xmm0                ; T(m)
    movsd xmm3, [k_two]
    mulsd xmm3, [rsi+32]
    mulsd xmm3, xmm2
    addsd xmm3, [rsi+40]
    movsd xmm4, xmm0
    addsd xmm4, xmm0                ; 2x
    mov ecx, 2
.m:
    movsd xmm5, xmm4
    mulsd xmm5, xmm2
    subsd xmm5, xmm1
    movsd xmm1, xmm2
    movsd xmm2, xmm5
    mov eax, 5
    sub eax, ecx
    movsd xmm5, [k_two]
    mulsd xmm5, [rsi+rax*8]
    mulsd xmm5, xmm2
    addsd xmm3, xmm5
    inc ecx
    cmp ecx, 5
    jbe .m
    movsd xmm0, xmm3
    ret

; rsi = g, rdi = roots out (8 max) -> eax = how many sign changes we found
; walks the grid from w=0 to pi, then bisects each crossing 20 times
find_roots:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rsi
    mov r13, rdi
    xor r14d, r14d
    movsd xmm0, [cosgrid]
    call cheb
    movsd [fr_prev], xmm0
    mov ebx, 1
.g:
    movsd xmm0, [cosgrid+rbx*8]
    mov rsi, r12
    call cheb
    movsd [fr_cur], xmm0
    xorpd xmm1, xmm1
    comisd xmm0, xmm1
    setb dl
    movsd xmm0, [fr_prev]
    comisd xmm0, xmm1
    setb dh
    cmp dl, dh
    je .next
    movsd xmm0, [cosgrid+rbx*8-8]
    movsd [fr_lo], xmm0
    movsd xmm0, [cosgrid+rbx*8]
    movsd [fr_hi], xmm0
    movsd xmm0, [fr_prev]
    movsd [fr_flo], xmm0
    push rbx
    mov ebx, 20
.bis:
    movsd xmm0, [fr_lo]
    addsd xmm0, [fr_hi]
    mulsd xmm0, [k_half]
    movsd xmm6, xmm0                ; mid
    mov rsi, r12
    call cheb
    xorpd xmm1, xmm1
    comisd xmm0, xmm1
    setb dl
    movsd xmm2, [fr_flo]
    comisd xmm2, xmm1
    setb dh
    cmp dl, dh
    jne .hi
    movsd [fr_lo], xmm6
    movsd [fr_flo], xmm0
    jmp .bn
.hi:
    movsd [fr_hi], xmm6
.bn:
    dec ebx
    jnz .bis
    pop rbx
    movsd xmm0, [fr_lo]
    addsd xmm0, [fr_hi]
    mulsd xmm0, [k_half]
    call f_acos
    cmp r14d, 8
    jae .full
    movsd [r13+r14*8], xmm0
.full:
    inc r14d
.next:
    movsd xmm0, [fr_cur]
    movsd [fr_prev], xmm0
    inc ebx
    cmp ebx, GRID
    jbe .g
    mov eax, r14d
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; lpc_a -> lsp_new. eax = 1 if we got 10 nicely ordered roots, 0 if not
lpc_to_lsp:
    ; P = A + z^-11 A(1/z), Q = A - z^-11 A(1/z), then knock out the roots at z=-1 and z=1
    movsd xmm0, [lpc_a]
    movsd [cheb_p], xmm0
    movsd [cheb_q], xmm0
    mov ecx, 1
.pq:
    mov eax, 11
    sub eax, ecx
    movsd xmm0, [lpc_a+rcx*8]
    movsd xmm1, xmm0
    addsd xmm0, [lpc_a+rax*8]
    subsd xmm1, [lpc_a+rax*8]
    subsd xmm0, [cheb_p+rcx*8-8]
    addsd xmm1, [cheb_q+rcx*8-8]
    movsd [cheb_p+rcx*8], xmm0
    movsd [cheb_q+rcx*8], xmm1
    inc ecx
    cmp ecx, 5
    jbe .pq

    mov rsi, cheb_p
    mov rdi, roots_p
    call find_roots
    cmp eax, 5
    jne .bad
    mov rsi, cheb_q
    mov rdi, roots_q
    call find_roots
    cmp eax, 5
    jne .bad
    xor ecx, ecx
.mix:
    lea rax, [rcx*2]
    movsd xmm0, [roots_p+rcx*8]
    movsd [lsp_new+rax*8], xmm0
    movsd xmm0, [roots_q+rcx*8]
    movsd [lsp_new+rax*8+8], xmm0
    inc ecx
    cmp ecx, 5
    jb .mix
    mov ecx, 1
.ord:
    movsd xmm0, [lsp_new+rcx*8]
    comisd xmm0, [lsp_new+rcx*8-8]
    jbe .bad
    inc ecx
    cmp ecx, P
    jb .ord
    mov eax, 1
    ret
.bad:
    xor eax, eax
    ret

; rsi = poly, edx = its length, xmm0 = c. poly *= (1 + c z^-1 + z^-2), in place
polymul:
    xor ecx, ecx
.cp:
    movsd xmm1, [rsi+rcx*8]
    movsd [poly_new+rcx*8], xmm1
    inc ecx
    cmp ecx, edx
    jb .cp
    xorpd xmm1, xmm1
    movsd [poly_new+rdx*8], xmm1
    movsd [poly_new+rdx*8+8], xmm1
    xor ecx, ecx
.k:
    movsd xmm1, [rsi+rcx*8]
    movsd xmm2, xmm1
    mulsd xmm2, xmm0
    addsd xmm2, [poly_new+rcx*8+8]
    movsd [poly_new+rcx*8+8], xmm2
    addsd xmm1, [poly_new+rcx*8+16]
    movsd [poly_new+rcx*8+16], xmm1
    inc ecx
    cmp ecx, edx
    jb .k
    lea eax, [rdx+2]
    xor ecx, ecx
.back:
    movsd xmm1, [poly_new+rcx*8]
    movsd [rsi+rcx*8], xmm1
    inc ecx
    cmp ecx, eax
    jb .back
    ret

; rsi = 10 lsps, rdi = 11 lpc out (a0 = 1)
lsp_to_lpc:
    push rbx
    push r12
    push r13
    mov r12, rsi
    mov r13, rdi
    movsd xmm0, [k_one]
    movsd [poly_p], xmm0
    movsd [poly_p+8], xmm0          ; P starts as 1 + z^-1
    movsd [poly_q], xmm0
    movsd xmm0, [k_mone]
    movsd [poly_q+8], xmm0          ; Q as 1 - z^-1
    xor ebx, ebx
.i:
    movsd xmm0, [r12+rbx*8]
    call f_cos
    mulsd xmm0, [k_mtwo]
    mov edx, ebx
    shr edx, 1
    lea edx, [rdx*2+2]
    mov rsi, poly_p
    test ebx, 1
    jz .even
    mov rsi, poly_q
.even:
    call polymul
    inc ebx
    cmp ebx, P
    jb .i
    movsd xmm0, [k_one]
    movsd [r13], xmm0
    mov ecx, 1
.out:
    movsd xmm0, [poly_p+rcx*8]
    addsd xmm0, [poly_q+rcx*8]
    mulsd xmm0, [k_half]
    movsd [r13+rcx*8], xmm0
    inc ecx
    cmp ecx, P
    jbe .out
    pop r13
    pop r12
    pop rbx
    ret

; rsi = old lsps, rdi = new lsps, edx = subframe 0..3, ecx = 1 to enforce the decoder's margin,
; r8 = 10 lsps out
lsp_interp:
    cvtsi2sd xmm0, edx
    addsd xmm0, [k_one]
    divsd xmm0, [k_four]            ; t = (1+sub)/4
    movsd xmm1, [k_one]
    subsd xmm1, xmm0
    xor eax, eax
.l:
    movsd xmm2, [rsi+rax*8]
    mulsd xmm2, xmm1
    movsd xmm3, [rdi+rax*8]
    mulsd xmm3, xmm0
    addsd xmm2, xmm3
    movsd [r8+rax*8], xmm2
    inc eax
    cmp eax, P
    jb .l
    test ecx, ecx
    jz .done

    movsd xmm0, [r8]
    movsd xmm1, [k_margin]
    comisd xmm0, xmm1
    jae .lo_ok
    movsd [r8], xmm1
.lo_ok:
    movsd xmm0, [r8+(P-1)*8]
    movsd xmm1, [k_pimarg]
    comisd xmm0, xmm1
    jbe .hi_ok
    movsd [r8+(P-1)*8], xmm1
.hi_ok:
    mov eax, 1
.m:
    movsd xmm0, [r8+rax*8]
    movsd xmm1, [r8+rax*8-8]
    addsd xmm1, [k_margin]
    comisd xmm0, xmm1
    jae .m1
    movsd xmm0, xmm1
    movsd [r8+rax*8], xmm0
.m1:
    movsd xmm1, [r8+rax*8+8]
    subsd xmm1, [k_margin]
    comisd xmm0, xmm1
    jbe .m2
    addsd xmm0, [r8+rax*8+8]
    subsd xmm0, [k_margin]
    mulsd xmm0, [k_half]
    movsd [r8+rax*8], xmm0
.m2:
    inc eax
    cmp eax, P-1
    jb .m
.done:
    ret
