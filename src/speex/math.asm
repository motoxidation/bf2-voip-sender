; math.asm - cos, acos, exp, ln on the good old x87.
; sse2 has no transcendentals and we have no libm, so this is the price.
; all take xmm0 and return xmm0. f_floor also eats xmm1 and returns rax.

section .data
align 16
k_sign:     dq 0x8000000000000000, 0
k_zero:     dq 0.0
k_one:      dq 1.0
k_mone:     dq -1.0
k_two:      dq 2.0
k_mtwo:     dq -2.0
k_half:     dq 0.5
k_mhalf:    dq -0.5
k_quarter:  dq 0.25
k_four:     dq 4.0
k_ten:      dq 10.0
k_pi:       dq 3.141592653589793
k_big:      dq 1e300

section .bss
alignb 8
fpt:        resq 1

section .text

f_cos:
    movsd [fpt], xmm0
    fld qword [fpt]
    fcos
    fstp qword [fpt]
    movsd xmm0, [fpt]
    ret

f_acos:
    movsd [fpt], xmm0
    fld qword [fpt]
    fld st0
    fmul st0, st0
    fld1
    fsubrp st1, st0         ; 1-x*x, x
    fsqrt
    fxch                    ; x, sqrt(1-x*x)
    fpatan                  ; atan2(sqrt(1-x*x), x)
    fstp qword [fpt]
    movsd xmm0, [fpt]
    ret

f_exp:
    movsd [fpt], xmm0
    fld qword [fpt]
    fldl2e
    fmulp st1, st0          ; y = x*log2(e)
    fld st0
    frndint                 ; n, y
    fsub st1, st0           ; n, y-n
    fxch
    f2xm1                   ; 2^f - 1, n
    fld1
    faddp st1, st0
    fscale                  ; 2^f * 2^n, n
    fstp st1
    fstp qword [fpt]
    movsd xmm0, [fpt]
    ret

f_ln:
    movsd [fpt], xmm0
    fldln2
    fld qword [fpt]
    fyl2x                   ; ln2 * log2(x)
    fstp qword [fpt]
    movsd xmm0, [fpt]
    ret

; no roundsd without sse4.1, so truncate and fix up negatives
f_floor:
    cvttsd2si rax, xmm0
    cvtsi2sd xmm1, rax
    comisd xmm1, xmm0
    jbe .ok
    dec rax
.ok:
    ret
