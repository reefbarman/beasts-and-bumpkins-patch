; Per-screen display mode for BEASTS.EXE (EU CD release).
;
; The front end (menus, briefing, videos) was drawn for 640x480, but the game
; runs everything at the DisplayWidth/DisplayHeight registry size. This code
; keeps 640x480 everywhere except in missions, which use the registry size.
;
; bbpatch.py appends the assembled bytes as a new PE section at VA 0x71F000
; and redirects the call sites listed in its HOOKS table to the entry points
; in the header below. Build: nasm -f bin -o screenmode.bin screenmode.asm
; Addresses and names come from research/display-and-screens.md.

bits 32
org 0x71F000

G_SCREEN        equ 0x48426C    ; 0 startup, 1 menus, 2 mission, 3 video
G_WIDTH         equ 0x484444
G_HEIGHT        equ 0x484448
DISPLAY         equ 0x4EEBC8    ; display object, methods are thiscall
READ_REGISTRY   equ 0x4064B0    ; reads DisplayWidth/DisplayHeight among others
CREATE_PRIMARY  equ 0x42EE50    ; Display_CreatePrimary()
CLEAR_SCREEN    equ 0x42F200    ; Display_ClearScreen()
SET_CLIP        equ 0x42F410    ; Display_SetClip(left, top, right, bottom)

D_DDRAW         equ 0x30        ; IDirectDraw*
D_PRIMARY       equ 0x34        ; IDirectDrawSurface* flip chain
D_PALETTE       equ 0xB8        ; IDirectDrawPalette*
DD_SETDISPLAYMODE   equ 0x54    ; IDirectDraw vtable
DDS_RELEASE         equ 0x08    ; IDirectDrawSurface vtable
DDS_SETPALETTE      equ 0x7C

FRONT_W         equ 640
FRONT_H         equ 480
PORTRAIT_INSET  equ 100         ; 640x480: portrait at 540,380

; ---------------------------------------------------------------- header
; bbpatch.py reads this table; keep the order in sync with its HOOKS.
header:
    db 'BBSM'
    dd 1                        ; version
    dd on_registry_read         ; +0x08
    dd on_enter_mission         ; +0x0C
    dd on_enter_menu            ; +0x10
    dd on_video_start           ; +0x14
    dd on_video_end             ; +0x18
    dd on_main_loop             ; +0x1C
    dd on_portrait_init         ; +0x20

mission_w   dd FRONT_W
mission_h   dd FRONT_H

; ---------------------------------------------------------------- hooks

; Replaces "call READ_REGISTRY" in WinMain (0x406B3A), before Display_Init.
; Keep the registry size for missions and start the display at 640x480.
on_registry_read:
    call READ_REGISTRY
    push eax
    mov eax, [G_WIDTH]
    cmp eax, FRONT_W
    jge .w
    mov eax, FRONT_W
.w: mov [mission_w], eax
    mov eax, [G_HEIGHT]
    cmp eax, FRONT_H
    jge .h
    mov eax, FRONT_H
.h: mov [mission_h], eax
    mov dword [G_WIDTH], FRONT_W
    mov dword [G_HEIGHT], FRONT_H
    pop eax
    ret

; Replace "mov dword [G_SCREEN], 2" (new game, load game, next mission).
; Runs before mission setup, so the map view is built at the mission size.
on_enter_mission:
    pushfd
    pushad
    push dword [mission_h]
    push dword [mission_w]
    call set_mode
    add esp, 8
    popad
    popfd
    mov dword [G_SCREEN], 2
    ret

; Replace "mov dword [G_SCREEN], 1" (back to the menus).
on_enter_menu:
    pushfd
    pushad
    push FRONT_H
    push FRONT_W
    call set_mode
    add esp, 8
    popad
    popfd
    mov dword [G_SCREEN], 1
    ret

; Replaces "mov dword [G_SCREEN], 3" in PlayVideo (0x432F0E). PlayVideo
; itself releases the primary and calls SetDisplayMode(g_width, g_height),
; so only the globals and clip need to change here.
on_video_start:
    pushfd
    pushad
    mov dword [G_WIDTH], FRONT_W
    mov dword [G_HEIGHT], FRONT_H
    push FRONT_H
    push FRONT_W
    push 0
    push 0
    mov ecx, DISPLAY
    call SET_CLIP
    popad
    popfd
    mov dword [G_SCREEN], 3
    ret

; Replaces "mov [G_SCREEN], ebp" where PlayVideo restores the previous
; screen (0x432F58, 0x4330DE). Videos played mid-mission go back to the
; mission size.
on_video_end:
    mov [G_SCREEN], ebp
    pushfd
    pushad
    call sync_mode
    popad
    popfd
    ret

; Replaces "mov eax, [G_SCREEN]" at the top of the main loop (0x40B244).
; Backstop for screen changes that don't go through the hooks above.
on_main_loop:
    pushfd
    pushad
    call sync_mode
    popad
    popfd
    mov eax, [G_SCREEN]
    ret

; Replaces "xor eax, eax; mov dword [ecx], 540" in the portrait constructor
; (0x42A310); the "mov dword [ecx+4], 380" after it is NOPed. Places the
; portrait relative to the mission size instead of 640x480.
on_portrait_init:
    mov eax, [mission_w]
    sub eax, PORTRAIT_INSET
    mov [ecx], eax
    mov eax, [mission_h]
    sub eax, PORTRAIT_INSET
    mov [ecx+4], eax
    xor eax, eax
    ret

; ---------------------------------------------------------------- helpers

; Mission size in state 2, 640x480 in states 0 and 1, untouched during video.
sync_mode:
    mov eax, [G_SCREEN]
    cmp eax, 2
    je .mission
    cmp eax, 1
    ja .done
    push FRONT_H
    push FRONT_W
    jmp .set
.mission:
    push dword [mission_h]
    push dword [mission_w]
.set:
    call set_mode
    add esp, 8
.done:
    ret

; set_mode(width, height), cdecl. Same sequence PlayVideo uses to come back
; from a video: release the flip chain, SetDisplayMode, recreate it, then
; clip, clear and palette.
set_mode:
    mov eax, [esp+4]
    mov edx, [esp+8]
    cmp eax, [G_WIDTH]
    jne .change
    cmp edx, [G_HEIGHT]
    je .ret
.change:
    push ebx
    mov ebx, DISPLAY
    mov [G_WIDTH], eax
    mov [G_HEIGHT], edx

    mov eax, [ebx+D_PRIMARY]
    test eax, eax
    jz .no_primary
    push eax
    mov ecx, [eax]
    call [ecx+DDS_RELEASE]
.no_primary:
    mov eax, [ebx+D_DDRAW]
    push 8
    push dword [G_HEIGHT]
    push dword [G_WIDTH]
    push eax
    mov ecx, [eax]
    call [ecx+DD_SETDISPLAYMODE]

    mov ecx, ebx
    call CREATE_PRIMARY

    push dword [G_HEIGHT]
    push dword [G_WIDTH]
    push 0
    push 0
    mov ecx, ebx
    call SET_CLIP

    mov ecx, ebx
    call CLEAR_SCREEN

    mov eax, [ebx+D_PALETTE]
    test eax, eax
    jz .no_palette
    mov ecx, [ebx+D_PRIMARY]
    push eax
    push ecx
    mov ecx, [ecx]
    call [ecx+DDS_SETPALETTE]
.no_palette:
    pop ebx
.ret:
    ret
