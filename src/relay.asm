; relay.asm - talking to the server's voice relay. plain udp, no handshake: the relay only
; cares that the session id belongs to a player on the server, and remembers where the
; packets come from.
;
;   audio:     [14 x 20 byte speex frames][frame counter u16][session u16][1]          squad
;              [14 x 20 byte speex frames][frame counter u16][1][session u16][2]       leader
;   keepalive: [session u16][6]
;
; everything little endian. the counter is the stream position of the packet's first frame.

FPP         equ 14                  ; frames per packet, same as the real client
AUDIO_LEN   equ FPP*20

section .data
s_nosock:   db "no udp socket for us. weird.", 0
s_nosend:   db "sendto failed. is the network up?", 0

section .bss
alignb 8
sa:         resb 16                 ; sockaddr_in of the relay
pkt:        resb AUDIO_LEN+8
sock_fd:    resd 1
session:    resd 1
leader:     resd 1                  ; 1 = leader channel

section .text

; rdi = "a.b.c.d" or "a.b.c.d:port" -> fills sa, CF set if it's garbage
parse_relay:
    mov word [sa], 2                ; AF_INET
    mov word [sa+2], 0x55d7         ; 55125, the default, already big endian
    mov qword [sa+8], 0
    xor r8d, r8d                    ; octet number
.oct:
    xor eax, eax
    xor edx, edx                    ; digits seen
.dig:
    movzx ecx, byte [rdi]
    sub ecx, '0'
    cmp ecx, 9
    ja .sep
    imul eax, eax, 10
    add eax, ecx
    inc edx
    inc rdi
    cmp edx, 3
    ja .bad
    jmp .dig
.sep:
    test edx, edx
    jz .bad
    cmp eax, 255
    ja .bad
    mov [sa+4+r8], al
    inc r8d
    movzx ecx, byte [rdi]
    cmp r8d, 4
    je .last
    cmp ecx, '.'
    jne .bad
    inc rdi
    jmp .oct
.last:
    test ecx, ecx
    jz .ok
    cmp ecx, ':'
    jne .bad
    inc rdi
    push rdi
    call parse_u
    pop rdi
    jc .bad
    test eax, eax
    jz .bad
    cmp eax, 65535
    ja .bad
    xchg al, ah
    mov [sa+2], ax
.ok:
    clc
    ret
.bad:
    stc
    ret

sock_open:
    mov edi, 2                      ; AF_INET
    mov esi, 2                      ; SOCK_DGRAM
    xor edx, edx
    mov eax, SYS_SOCKET
    syscall
    test eax, eax
    js .fail
    mov [sock_fd], eax
    ret
.fail:
    mov rdi, s_nosock
    jmp die

; rsi = buffer, edx = length
sock_send:
    mov edi, [sock_fd]
    xor r10d, r10d
    mov r8, sa
    mov r9d, 16
    mov eax, SYS_SENDTO
    syscall
    test rax, rax
    js .fail
    ret
.fail:
    mov rdi, s_nosend
    jmp die

send_keepalive:
    mov eax, [session]
    mov [pkt+AUDIO_LEN], ax
    mov byte [pkt+AUDIO_LEN+2], 6
    mov rsi, pkt+AUDIO_LEN
    mov edx, 3
    jmp sock_send

; ecx = frame counter. pkt already holds the 14 frames
send_audio:
    mov [pkt+AUDIO_LEN], cx
    mov eax, [session]
    cmp dword [leader], 0
    jne .lead
    mov [pkt+AUDIO_LEN+2], ax
    mov byte [pkt+AUDIO_LEN+4], 1
    mov edx, AUDIO_LEN+5
    jmp .go
.lead:
    mov byte [pkt+AUDIO_LEN+2], 1
    mov [pkt+AUDIO_LEN+3], ax
    mov byte [pkt+AUDIO_LEN+5], 2
    mov edx, AUDIO_LEN+6
.go:
    mov rsi, pkt
    jmp sock_send
