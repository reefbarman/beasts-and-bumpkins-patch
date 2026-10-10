; Quality-of-life additions for BEASTS.EXE (EU CD release), installed at
; every resolution: WASD camera scrolling, F5 quicksave, F9 quickload, and
; skipping videos with any key or mouse click.
;
; bbpatch.py appends the assembled bytes as a new PE section at VA 0x71F000
; (the first free one, so screenmode follows it at 0x720000) and redirects the
; sites in its QOL_HOOKS table to the entry points in the header below.
; Build: nasm -f bin -o qol.bin qol.asm
; Addresses and names come from research/display-and-screens.md.

bits 32
org 0x71F000

G_SCREEN        equ 0x48426C    ; 0 startup, 1 menus, 2 mission, 3 video
VIEW_MODE       equ 0x48443C    ; mission view; 4 = briefing, 5 = video
MENU_ACTIVE     equ 0x5CA308    ; first dword of the menu object (pause menu in missions)
INPUT_MODE      equ 0x4847B4    ; non-zero while typing (save names etc.)
DISPLAY         equ 0x4EEBC8    ; display object, methods are thiscall
CLEAR_SCREEN    equ 0x42F200    ; Display_ClearScreen()
REQUEST_REDRAW  equ 0x403190    ; full map repaint for every buffer in the flip chain
SAVE_GAME       equ 0x4159C0    ; cdecl SaveGame(path, description), 1 on success
LOAD_GAME       equ 0x415ED0    ; cdecl LoadGame(path, from_archive)
FOPEN           equ 0x46BDD0    ; cdecl fopen(path, mode)
FCLOSE          equ 0x46BBD0    ; cdecl fclose(file)
SHOW_MESSAGE    equ 0x41DE40    ; thiscall Messages_Add(text), on MESSAGES
MESSAGES        equ 0x662C98
VK_F5           equ 0x74
VK_F9           equ 0x78
VIDEO_FRAME_BODY equ 0x42EB87   ; video callback after its first 7 bytes
VIDEO_MSG_STOP  equ 0x42EBCB    ; video callback: return 1 (stop the video)
VIDEO_MSG_DISPATCH equ 0x42EBD5 ; video callback: TranslateMessage, DispatchMessage
WM_KEYDOWN      equ 0x100
WM_LBUTTONDOWN  equ 0x201
WM_RBUTTONDOWN  equ 0x204
WM_MBUTTONDOWN  equ 0x207
KEY_REPEAT      equ 0x40000000  ; lParam bit 30: key was already down
VK_ESCAPE       equ 0x1B
SKIP_WINDOW     equ 2000        ; ms to press again after the prompt shows
IAT_GET_TICK    equ 0x6CA378    ; GetTickCount
IAT_GET_MODULE  equ 0x6CA39C    ; GetModuleHandleA
IAT_GET_PROC    equ 0x6CA4AC    ; GetProcAddress
DDRAW           equ 0x4EEBF8    ; IDirectDraw (display object +0x30)
PROMPT_H        equ 36          ; strip at the bottom of the frame
PROMPT_FONT_H   equ 18
PROMPT_COLOR    equ 0x0060D0F0  ; COLORREF, warm yellow
BLACK_BRUSH     equ 4
TRANSPARENT     equ 1
FW_BOLD         equ 700
NONANTIALIASED_QUALITY equ 3
DT_CENTER_VCENTER_SINGLELINE equ 0x25
DDSD_SIZE       equ 0x6C        ; DDSURFACEDESC
DDSD_HEIGHT     equ 0x08
DDSD_WIDTH      equ 0x0C

; ---------------------------------------------------------------- header
; bbpatch.py reads this table; keep the order in sync with its QOL_HOOKS.
header:
    db 'BBQL'
    dd 2                        ; version
    dd on_key_down              ; +0x08
    dd on_key_up                ; +0x0C
    dd on_main_loop             ; +0x10
    dd on_video_message         ; +0x14
    dd on_video_frame           ; +0x18

; ---------------------------------------------------------------- hooks

; WASD camera scrolling. The window procedure already maps the arrow keys
; to the scroll flags 0x484520 (up), 0x484524 (down), 0x484528 (left) and
; 0x48452C (right) through two jump tables: key down at 0x403F5F (vk - 0x25,
; 0x99 entries) and key up at 0x405493 (vk - 0x10, 0x19 entries). ebx holds
; the virtual-key code at both. Translate W/A/S/D to the arrow codes for the
; table lookup only, leaving ebx alone.

; Jumped to from 0x403F5F; replaces "lea eax, [ebx-0x25]; cmp eax, 0x98".
on_key_down:
    call quick_key_down
    call wasd_to_arrow
    sub eax, 0x25
    cmp eax, 0x98
    jmp 0x403F67

; Jumped to from 0x405493; replaces "lea eax, [ebx-0x10]; cmp eax, 0x18".
on_key_up:
    cmp ebx, [qs_held]
    jne .up
    mov dword [qs_held], 0
.up:
    call wasd_to_arrow
    sub eax, 0x10
    cmp eax, 0x18
    jmp 0x405499

; Replaces "mov eax, [G_SCREEN]" in the main loop (0x40B287), reached on
; every iteration once past startup. (screenmode hooks the same instruction
; at 0x40B244, just before.)
on_main_loop:
    pushfd
    pushad
    call run_quick_action
    popad
    popfd
    mov eax, [G_SCREEN]
    ret

; ---------------------------------------------------------------- video skip
; The video player loop (0x45A980) calls 0x42EB80 once per frame; it reads
; one window message and returns 1 to stop the video. The original stops
; only on Escape. Now Escape still stops at once, and any other new key
; press or mouse button press shows "Press again to skip" at the bottom of
; the frame; a second press within SKIP_WINDOW ms stops the video, otherwise
; the prompt goes away. Auto-repeat doesn't count (a key held from before
; the video doesn't arm it), nor does Alt (WM_SYSKEYDOWN), so Alt+Enter
; doesn't skip.

; Jumped to from 0x42EB80 (replaces "sub esp, 0x1C; lea eax, [esp]"), every
; frame, after the previous frame was drawn: keep the prompt on screen (the
; player redraws the whole frame) or time it out.
on_video_frame:
    pushfd
    pushad
    mov eax, [skip_until]
    test eax, eax
    jz .ret
    call [IAT_GET_TICK]
    sub eax, [skip_until]
    js .draw
    mov dword [skip_until], 0
    xor eax, eax
    call draw_skip_prompt
    jmp .ret
.draw:
    mov eax, 1
    call draw_skip_prompt
.ret:
    popad
    popfd
    sub esp, 0x1C
    lea eax, [esp]
    jmp VIDEO_FRAME_BODY

; Jumped to from 0x42EBB7 (replaces "mov eax, [msg.message]; cmp eax,
; WM_KEYDOWN") once a message has been read; [esp+4] is the MSG.
on_video_message:
    mov eax, [esp+8]            ; message
    cmp eax, WM_KEYDOWN
    jne .mouse
    cmp dword [esp+12], VK_ESCAPE
    je .stop
    test dword [esp+16], KEY_REPEAT
    jnz .dispatch
    jmp .press
.mouse:
    cmp eax, WM_LBUTTONDOWN
    je .press
    cmp eax, WM_RBUTTONDOWN
    je .press
    cmp eax, WM_MBUTTONDOWN
    jne .dispatch
.press:
    call [IAT_GET_TICK]
    mov ecx, [skip_until]
    test ecx, ecx
    jz .arm
    cmp eax, ecx
    js .stop                    ; second press in time
.arm:
    add eax, SKIP_WINDOW
    or eax, 1                   ; 0 means not armed
    mov [skip_until], eax
    pushad
    mov eax, 1
    call draw_skip_prompt
    popad
.dispatch:
    jmp VIDEO_MSG_DISPATCH      ; as the original does for other messages
.stop:
    mov dword [skip_until], 0
    jmp VIDEO_MSG_STOP

; eax = 1: draw the prompt, 0: clear it. Draws with GDI on the primary
; surface (IDirectDraw::GetGDISurface, which cnc-ddraw returns without
; AddRef) in a strip at the bottom of the frame, which the videos leave
; black. The strip comes from the surface size: cnc-ddraw's DC bitmap is
; taller than the mode (GetClipBox says 640x680 for 640x480). Clobbers eax,
; ecx, edx.
draw_skip_prompt:
    push ebp
    mov ebp, esp
    sub esp, 32 + DDSD_SIZE     ; -4 flag, -8 surface, -12 hdc,
                                ; -16 previous font, -32 rect, then desc
    mov [ebp-4], eax
    call resolve_gdi
    test eax, eax
    jz .out
    mov ecx, [DDRAW]
    test ecx, ecx
    jz .out
    lea eax, [ebp-8]
    push eax
    push ecx
    mov eax, [ecx]
    call [eax+0x38]             ; GetGDISurface
    test eax, eax
    jnz .out
    mov ecx, [ebp-8]
    test ecx, ecx
    jz .out
    lea edx, [ebp-32-DDSD_SIZE]
    mov dword [edx], DDSD_SIZE
    push edx
    push ecx
    mov eax, [ecx]
    call [eax+0x58]             ; GetSurfaceDesc
    test eax, eax
    jnz .out
    mov dword [ebp-32], 0       ; rect: bottom PROMPT_H rows, full width
    mov eax, [ebp-32-DDSD_SIZE+DDSD_WIDTH]
    mov [ebp-32+8], eax
    mov eax, [ebp-32-DDSD_SIZE+DDSD_HEIGHT]
    mov [ebp-32+12], eax
    sub eax, PROMPT_H
    mov [ebp-32+4], eax
    mov ecx, [ebp-8]
    lea eax, [ebp-12]
    push eax
    push ecx
    mov eax, [ecx]
    call [eax+0x44]             ; GetDC
    test eax, eax
    jnz .out

    push BLACK_BRUSH
    call [p_GetStockObject]
    push eax
    lea eax, [ebp-32]
    push eax
    push dword [ebp-12]
    call [p_FillRect]
    cmp dword [ebp-4], 0
    je .release

    mov eax, [prompt_font]
    test eax, eax
    jnz .font
    push str_font_face
    push 0                      ; pitch and family
    push NONANTIALIASED_QUALITY
    push 0                      ; clip precision
    push 0                      ; out precision
    push 0                      ; charset ANSI
    push 0                      ; strike out
    push 0                      ; underline
    push 0                      ; italic
    push FW_BOLD
    push 0                      ; orientation
    push 0                      ; escapement
    push 0                      ; width
    push -PROMPT_FONT_H
    call [p_CreateFontA]
    mov [prompt_font], eax
.font:
    push eax
    push dword [ebp-12]
    call [p_SelectObject]
    mov [ebp-16], eax
    push TRANSPARENT
    push dword [ebp-12]
    call [p_SetBkMode]
    push PROMPT_COLOR
    push dword [ebp-12]
    call [p_SetTextColor]
    push DT_CENTER_VCENTER_SINGLELINE
    lea eax, [ebp-32]
    push eax
    push -1
    push str_skip_prompt
    push dword [ebp-12]
    call [p_DrawTextA]
    mov eax, [ebp-16]
    test eax, eax
    jz .release
    push eax
    push dword [ebp-12]
    call [p_SelectObject]
.release:
    push dword [ebp-12]
    mov ecx, [ebp-8]
    push ecx
    mov eax, [ecx]
    call [eax+0x68]             ; ReleaseDC
.out:
    mov esp, ebp
    pop ebp
    ret

; Look up the GDI and user32 functions once (the game doesn't import them).
; eax = 1 when all are available. Clobbers ecx, edx.
resolve_gdi:
    mov eax, [gdi_ready]
    test eax, eax
    jnz .ret
    push ebx
    push esi
    push edi
    mov esi, gdi_names
    mov edi, gdi_procs
.module:
    cmp byte [esi], 0
    je .done
    push esi
    call [IAT_GET_MODULE]
    test eax, eax
    jz .fail
    mov ebx, eax
.skip_module:
    lodsb
    test al, al
    jnz .skip_module
.proc:
    cmp byte [esi], 0
    je .next_module
    push esi
    push ebx
    call [IAT_GET_PROC]
    test eax, eax
    jz .fail
    stosd
.skip_proc:
    lodsb
    test al, al
    jnz .skip_proc
    jmp .proc
.next_module:
    inc esi
    jmp .module
.done:
    mov dword [gdi_ready], 1
    mov eax, 1
.fail:
    pop edi
    pop esi
    pop ebx
.ret:
    ret

; eax = ebx, with W/A/S/D replaced by VK_UP/LEFT/DOWN/RIGHT.
wasd_to_arrow:
    mov eax, ebx
    cmp eax, 'W'
    jne .a
    mov eax, 0x26
    ret
.a: cmp eax, 'A'
    jne .s
    mov eax, 0x25
    ret
.s: cmp eax, 'S'
    jne .d
    mov eax, 0x28
    ret
.d: cmp eax, 'D'
    jne .done
    mov eax, 0x27
.done:
    ret

; Quicksave (F5) and quickload (F9) in missions. The game has no use for
; either key (both fall to the table's no-op entry). The key handler runs in
; the window procedure, so it only records the request; the main loop runs it
; between frames. Auto-repeat is ignored until the key comes back up. Uses
; its own file, so the menu slots are safe.

; ebx = virtual-key code. Preserves registers.
quick_key_down:
    cmp ebx, VK_F5
    je .key
    cmp ebx, VK_F9
    jne .done
.key:
    cmp ebx, [qs_held]
    je .done                    ; auto-repeat
    mov [qs_held], ebx
    cmp dword [G_SCREEN], 2
    jne .done
    cmp dword [INPUT_MODE], 0
    jne .done
    cmp dword [MENU_ACTIVE], 0
    jne .done
    mov [qs_pending], ebx
.done:
    ret

; Called from the main loop inside pushad. Same sequences as the pause menu's
; Save (0x41FF18) and Load (0x41FD79) items, minus closing the menu.
run_quick_action:
    mov eax, [qs_pending]
    test eax, eax
    jz .ret
    mov dword [qs_pending], 0
    cmp dword [G_SCREEN], 2
    jne .ret
    cmp dword [MENU_ACTIVE], 0
    jne .ret
    cmp dword [VIEW_MODE], 4    ; briefing
    je .ret
    cmp dword [VIEW_MODE], 5    ; video
    je .ret
    push ebp
    mov ebp, esp                ; restored at the end, whatever the callees do
    cmp eax, VK_F5
    jne .load

    push qs_desc
    push qs_file
    call SAVE_GAME
    mov edx, msg_saved
    test eax, eax
    jnz .message
    mov edx, msg_save_failed
    jmp .message

.load:
    ; LoadGame tears the mission down before it opens the file, so check
    ; that there is a quicksave first.
    push qs_mode_rb
    push qs_file
    call FOPEN
    mov esp, ebp
    mov edx, msg_no_save
    test eax, eax
    jz .message
    push eax
    call FCLOSE
    mov esp, ebp

    push 0x6AFBE8
    push 0x5CA200
    mov ecx, 0x513458
    call 0x401110
    mov dword [0x484274], 0
    mov ecx, DISPLAY
    call CLEAR_SCREEN
    push 0
    push qs_file
    call LOAD_GAME
    mov esp, ebp
    call REQUEST_REDRAW
    mov dword [0x484278], 0
    call 0x42E060
    cmp byte [0x4843DC], 0
    je .music
    call 0x42E460
.music:
    movzx eax, byte [0x5E5CC3]
    push eax
    mov ecx, 0x6A9950
    call 0x42B480
    mov esp, ebp
    mov edx, msg_loaded

.message:
    mov esp, ebp
    push edx
    mov ecx, MESSAGES
    call SHOW_MESSAGE
    mov esp, ebp
    pop ebp
.ret:
    ret

qs_pending      dd 0            ; VK_F5 / VK_F9 waiting for the main loop
qs_held         dd 0            ; key down and not yet released
qs_file         db 'quicksav.sav', 0
qs_desc         db 'Quicksave', 0
qs_mode_rb      db 'rb', 0
msg_saved       db 'Game saved (F9 to load)', 0
msg_save_failed db 'Quicksave failed', 0
msg_loaded      db 'Quicksave loaded', 0
msg_no_save     db 'No quicksave yet (F5 to save)', 0

skip_until      dd 0            ; GetTickCount until a second press skips, 0 = not armed
prompt_font     dd 0
gdi_ready       dd 0
gdi_procs:                      ; filled in gdi_names order
p_GetStockObject dd 0
p_CreateFontA   dd 0
p_SelectObject  dd 0
p_SetBkMode     dd 0
p_SetTextColor  dd 0
p_FillRect      dd 0
p_DrawTextA     dd 0
gdi_names       db 'gdi32.dll', 0
                db 'GetStockObject', 0, 'CreateFontA', 0
                db 'SelectObject', 0, 'SetBkMode', 0, 'SetTextColor', 0, 0
                db 'user32.dll', 0
                db 'FillRect', 0, 'DrawTextA', 0, 0
                db 0
str_font_face   db 'Arial', 0
str_skip_prompt db 'Press again to skip', 0
