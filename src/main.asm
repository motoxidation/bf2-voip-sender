; alger - says things into a battlefield 2 squad channel.
;
; takes a wav (or raw 8 kHz s16 on stdin), encodes it to speex narrowband the way the bf2
; client does at voipQuality 3, and sends it to the server's voice relay as 14 frame
; packets, one every 280 ms, under the session id you give it.
;
; x86-64 linux, no libc. make, then ./alger --help

bits 64
default abs

%include "speex/speex.inc"
%include "sys.asm"
%include "wav.asm"
%include "relay.asm"
%include "speex/math.asm"
%include "speex/tables.inc"
%include "speex/filt.asm"
%include "speex/lpc.asm"
%include "speex/quant.asm"
%include "speex/ltp.asm"
%include "speex/cb.asm"
%include "speex/nb_enc.asm"

PKT_NS      equ 280000000           ; one packet of audio
FRAME_NS    equ 20000000
KA_NS       equ 3000000000          ; keepalive every 3 s, or the relay forgets us
PCM_BYTES   equ FPP*N*2

section .data
s_usage:
    db "usage: alger --relay ip[:port] --session id [--channel squad|leader] (--wav file | --stdin)", 10
    db 10
    db "  --relay    the server's voice relay, port defaults to 55125", 10
    db "  --session  your voice session id, 0-65535", 10
    db "  --channel  squad (default) or leader", 10
    db "  --wav      16-bit or float wav, any rate, mono or stereo", 10
    db "  --stdin    raw s16le mono at 8 kHz, ffmpeg -f s16le -ar 8000 -ac 1 -", 10
    db 10
    db "why? because we can't find the real alger :D", 10, 0

o_relay:    db "--relay", 0
o_session:  db "--session", 0
o_channel:  db "--channel", 0
o_wav:      db "--wav", 0
o_stdin:    db "--stdin", 0
o_help:     db "--help", 0
o_h:        db "-h", 0
c_squad:    db "squad", 0
c_leader:   db "leader", 0

s_unknown:  db "never heard of ", 0
s_needs:    db "that one needs a value: ", 0
s_norelay:  db "no --relay. where am i supposed to shout?", 0
s_nosess:   db "no --session. the relay doesn't know who you are, lagoon.", 0
s_pick:     db "pick one: --wav file or --stdin", 0
s_badrelay: db "--relay wants a dotted ipv4, like 203.0.113.5:55125", 0
s_badsess:  db "--session is a number from 0 to 65535", 0
s_badchan:  db "--channel is squad or leader", 0
s_hello1:   db "alger: talking to ", 0
s_hello2:   db " as session ", 0
s_hello3:   db " on ", 0
s_bye1:     db "alger: done, ", 0
s_bye2:     db " packets. alger has spoken.", 10, 0

section .bss
alignb 8
arg_relay:  resq 1
arg_wav:    resq 1
arg_chan:   resq 1
t0:         resq 1
last_ka:    resq 1
src_ptr:    resq 1                  ; wav samples not sent yet
src_left:   resq 1
sent:       resq 1
pos_next:   resq 1
pcm:        resb PCM_BYTES
pollfd:     resq 1
have_sess:  resd 1
use_stdin:  resd 1
eof:        resd 1

section .text
global _start
_start:
    mov r12, [rsp]                  ; argc
    lea r13, [rsp+16]               ; argv[1]
    dec r12
    jz usage
    mov qword [arg_chan], c_squad
.arg:
    test r12, r12
    jz .args_done
    mov rsi, [r13]
    mov rdi, o_help
    call streq
    je usage
    mov rsi, [r13]
    mov rdi, o_h
    call streq
    je usage
    mov rsi, [r13]
    mov rdi, o_stdin
    call streq
    jne .valued
    mov dword [use_stdin], 1
    add r13, 8
    dec r12
    jmp .arg
.valued:
    cmp r12, 2                      ; everything else takes a value
    jb .needs
    mov rbx, [r13+8]
    mov rsi, [r13]
    mov rdi, o_relay
    call streq
    jne .a1
    mov [arg_relay], rbx
    jmp .shift
.a1:
    mov rsi, [r13]
    mov rdi, o_session
    call streq
    jne .a2
    mov rdi, rbx
    call parse_u
    jc .badsess
    cmp rax, 65535
    ja .badsess
    mov [session], eax
    mov dword [have_sess], 1
    jmp .shift
.a2:
    mov rsi, [r13]
    mov rdi, o_channel
    call streq
    jne .a3
    mov [arg_chan], rbx
    mov rsi, rbx
    mov rdi, c_squad
    call streq
    je .shift
    mov rsi, rbx
    mov rdi, c_leader
    call streq
    jne .badchan
    mov dword [leader], 1
    jmp .shift
.a3:
    mov rsi, [r13]
    mov rdi, o_wav
    call streq
    jne .unknown
    mov [arg_wav], rbx
.shift:
    add r13, 16
    sub r12, 2
    jmp .arg
.unknown:
    mov rdi, s_unknown
    mov rsi, [r13]
    jmp die2
.needs:
    mov rdi, s_needs
    mov rsi, [r13]
    jmp die2
.badsess:
    mov rdi, s_badsess
    jmp die
.badchan:
    mov rdi, s_badchan
    jmp die

.args_done:
    cmp qword [arg_relay], 0
    jne .r1
    mov rdi, s_norelay
    jmp die
.r1:
    cmp dword [have_sess], 0
    jne .r2
    mov rdi, s_nosess
    jmp die
.r2:
    xor eax, eax
    cmp qword [arg_wav], 0
    setne al
    add eax, [use_stdin]
    cmp eax, 1
    je .r3
    mov rdi, s_pick
    jmp die
.r3:
    mov rdi, [arg_relay]
    call parse_relay
    jnc .r4
    mov rdi, s_badrelay
    jmp die
.r4:
    call enc_init
    cmp dword [use_stdin], 0
    jne .r5
    mov rdi, [arg_wav]
    call wav_load
    mov [src_ptr], rax
    mov [src_left], rdx
.r5:
    call sock_open

    mov rdi, s_hello1
    call eputs
    mov rdi, [arg_relay]
    call eputs
    mov rdi, s_hello2
    call eputs
    mov eax, [session]
    call utoa
    call eputs
    mov rdi, s_hello3
    call eputs
    mov rdi, [arg_chan]
    call eputs
    mov rdi, s_nl
    call eputs

    call now_ns
    mov [t0], rax
    mov [last_ka], rax
    call send_keepalive

.loop:
    call fill_pcm
    test eax, eax
    jz .done
    xor ebx, ebx
.enc:
    imul eax, ebx, N*2
    lea rsi, [pcm+rax]
    imul eax, ebx, 20
    lea rdi, [pkt+rax]
    call enc_frame
    inc ebx
    cmp ebx, FPP
    jb .enc

    mov rax, [sent]
    imul rax, rax, PKT_NS
    add rax, [t0]
    mov rdi, rax
    call sleep_until

    ; the counter runs on like a real client's. if we fell way behind (stdin went
    ; quiet) jump it forward to where the clock says we are
    call now_ns
    sub rax, [t0]
    xor edx, edx
    mov ecx, FRAME_NS
    div rcx
    mov rdx, [pos_next]
    add rdx, FPP
    cmp rax, rdx
    jbe .cnt
    mov [pos_next], rax
.cnt:
    mov ecx, [pos_next]
    call send_audio
    add qword [pos_next], FPP
    inc qword [sent]
    call keepalive_due
    jmp .loop

.done:
    mov rdi, s_bye1
    call eputs
    mov rax, [sent]
    call utoa
    call eputs
    mov rdi, s_bye2
    call eputs
    xor edi, edi
    mov eax, SYS_EXIT
    syscall

usage:
    mov rdi, s_usage
    mov esi, 1
    call fputs
    xor edi, edi
    mov eax, SYS_EXIT
    syscall

keepalive_due:
    call now_ns
    mov rdx, rax
    sub rdx, [last_ka]
    mov rcx, KA_NS
    cmp rdx, rcx
    jb .no
    mov [last_ka], rax
    call send_keepalive
.no:
    ret

; next 14 frames of input into pcm, zero padded at the end. eax = 0 when there's nothing left
fill_pcm:
    cmp dword [use_stdin], 0
    jne .stdin
    mov rcx, [src_left]
    test rcx, rcx
    jz .empty
    cmp rcx, FPP*N
    jbe .wn
    mov ecx, FPP*N
.wn:
    sub [src_left], rcx
    mov rsi, [src_ptr]
    mov rdi, pcm
    lea rax, [rsi+rcx*2]
    mov [src_ptr], rax
    mov edx, FPP*N
    sub edx, ecx
    rep movsw
    mov ecx, edx
    xor eax, eax
    rep stosw
    mov eax, 1
    ret
.empty:
    xor eax, eax
    ret

.stdin:
    cmp dword [eof], 0
    jne .empty
    push rbx
    xor ebx, ebx                    ; bytes we have
.rd:
    cmp ebx, PCM_BYTES
    jae .full
    mov dword [pollfd], 0           ; fd 0, POLLIN
    mov word [pollfd+4], 1
    mov rdi, pollfd
    mov esi, 1
    mov edx, 1000
    mov eax, SYS_POLL
    syscall
    test eax, eax
    jnz .ready
    call keepalive_due              ; nothing to say right now, but stay known to the relay
    jmp .rd
.ready:
    js .rd                          ; interrupted, try again
    xor edi, edi
    lea rsi, [pcm+rbx]
    mov edx, PCM_BYTES
    sub edx, ebx
    mov eax, SYS_READ
    syscall
    cmp rax, -EINTR
    je .rd
    test rax, rax
    jle .eof
    add ebx, eax
    jmp .rd
.eof:
    mov dword [eof], 1
    test ebx, ebx
    jz .nothing
    lea rdi, [pcm+rbx]
    mov ecx, PCM_BYTES
    sub ecx, ebx
    xor eax, eax
    rep stosb
.full:
    pop rbx
    mov eax, 1
    ret
.nothing:
    pop rbx
    xor eax, eax
    ret
