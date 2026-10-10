; Quality-of-life additions for BEASTS.EXE (EU CD release), installed at
; every resolution: WASD camera scrolling, F5 quicksave and F9 quickload.
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

; ---------------------------------------------------------------- header
; bbpatch.py reads this table; keep the order in sync with its QOL_HOOKS.
header:
    db 'BBQL'
    dd 1                        ; version
    dd on_key_down              ; +0x08
    dd on_key_up                ; +0x0C
    dd on_main_loop             ; +0x10

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
