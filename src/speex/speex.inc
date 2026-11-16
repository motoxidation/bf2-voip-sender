; sizes for speex narrowband, shared by everything under speex/

N       equ 160         ; samples per frame, 20 ms at 8 kHz
L       equ 40          ; samples per subframe
P       equ 10          ; lpc order
PMIN    equ 17          ; pitch range the bitstream can carry
PMAX    equ 144
WIN     equ 240         ; analysis window: 40 old + 160 frame + 40 lookahead
FRM     equ 40          ; where the frame starts inside the window
EXH     equ 160         ; excitation history kept in front of the frame
SWBASE  equ PMAX+2      ; weighted speech history kept in front of the frame
SWLEN   equ SWBASE+N
NCAND   equ 6           ; open loop pitch guesses that get the full closed loop treatment
GRID    equ 512         ; steps over 0..pi when hunting lsp roots
