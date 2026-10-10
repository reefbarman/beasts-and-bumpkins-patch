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
VIEW_MODE       equ 0x48443C    ; mission view; 4 = briefing, 5 = video
MENU_ACTIVE     equ 0x5CA308    ; first dword of the menu object (pause menu in missions)
DISPLAY         equ 0x4EEBC8    ; display object, methods are thiscall
READ_REGISTRY   equ 0x4064B0    ; reads DisplayWidth/DisplayHeight among others
CREATE_PRIMARY  equ 0x42EE50    ; Display_CreatePrimary()
CLEAR_SCREEN    equ 0x42F200    ; Display_ClearScreen()
SET_CLIP        equ 0x42F410    ; Display_SetClip(left, top, right, bottom)
REQUEST_REDRAW  equ 0x403190    ; full map repaint for every buffer in the flip chain
REDRAW_FRAMES   equ 0x4847BC    ; byte: frames of full repaint left (0x40BBA0)
TOOLBAR_H       equ 0x29        ; top toolbar height; the map viewport starts below it
D_BACK          equ 0x38        ; IDirectDrawSurface* back buffer
DDS_BLT         equ 0x14        ; IDirectDrawSurface vtable
DDBLT_COLORFILL_WAIT equ 0x01000400
SPRITE_BLIT     equ 0x42FD90    ; thiscall Sprite_Blit(x, y, frame or 0xFF, to_back), ret 16
; Wide toolbar: the 640-wide image is cut at TB_SPLIT. The left part stays,
; the right part (slots and the hand) is anchored to the right edge, and the
; gap is filled with a plain stone slice of the image.
TB_SPLIT        equ 400         ; after the last button (0x17C), before slot 5 (0x1B1)
TB_TILE_SRC     equ 400         ; plain stone slice used as filler
TB_TILE_W       equ 64
TB_DEAD_X       equ 0x17D       ; an x no toolbar button or slot answers to


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
    dd 4                        ; version
    dd on_registry_read         ; +0x08
    dd on_enter_mission         ; +0x0C
    dd on_enter_menu            ; +0x10
    dd on_video_start           ; +0x14
    dd on_video_end             ; +0x18
    dd on_main_loop             ; +0x1C
    dd on_portrait_init         ; +0x20
    dd on_menu_open_close       ; +0x24
    dd on_set_view_mode         ; +0x28
    dd on_mission_frame         ; +0x2C
    dd on_before_toolbar        ; +0x30
    dd on_toolbar_bg            ; +0x34
    dd on_toolbar_slots         ; +0x38
    dd on_toolbar_click         ; +0x3C
    dd on_toolbar_tip           ; +0x40
    dd on_season_x              ; +0x44
    dd push_season_x2           ; +0x48
    dd cmp_season_lo            ; +0x4C
    dd cmp_season_hi            ; +0x50
    dd push_cheat_x             ; +0x54
    dd push_tab_x1              ; +0x58
    dd push_tab_x2              ; +0x5C
    dd cmp_tab_lo               ; +0x60
    dd cmp_tab_hi               ; +0x64
    dd on_panel_fill            ; +0x68
    dd on_key_down              ; +0x6C
    dd on_key_up                ; +0x70

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

; Jumped to from the entry of Menu_SetActive(flag) (0x41FFC0, thiscall),
; which clears the screen and draws the menu background (flag 1) or the
; mission panel (flag 0) once. Switch first, using the pending flag, then run
; the 8 displaced bytes and continue.
on_menu_open_close:
    pushfd
    pushad
    push dword [VIEW_MODE]
    push dword [esp+44]         ; flag (4 pushfd + 32 pushad + 4 view + ret)
    call sync_for
    add esp, 8
    popad
    popfd
    push esi
    push edi
    mov esi, ecx
    mov ecx, [esp+0xC]
    jmp 0x41FFC8

; Jumped to from the entry of SetViewMode(mode) (0x42B260, cdecl). Entering
; mode 4 (briefing) clears and draws the briefing background once; leaving it
; redraws the mission panel. Switch first, using the pending mode.
on_set_view_mode:
    pushfd
    pushad
    push dword [esp+40]         ; mode (4 pushfd + 32 pushad + ret)
    push dword [MENU_ACTIVE]
    call sync_for
    add esp, 8
    popad
    popfd
    push esi
    mov eax, [VIEW_MODE]
    jmp 0x42B266

; Replaces "mov al, [REDRAW_FRAMES]" at the top of the mission frame
; (0x40BBA1). The game repaints only dirty rects, and several HUD overlays
; (thought bubble, tooltips) only mark where they are now, not where they
; were, so above 640x480 they smear. Repaint everything every frame instead,
; as the game already does while scrolling.
on_mission_frame:
    cmp dword [G_WIDTH], FRONT_W
    jle .orig
    cmp byte [REDRAW_FRAMES], 0
    jne .orig
    mov byte [REDRAW_FRAMES], 1
.orig:
    mov al, [REDRAW_FRAMES]
    ret

; Replaces "mov ecx, 0x5D19A0" before the toolbar draw (0x40BEF2). The
; toolbar image is 640 wide and the map starts below it, so nothing repaints
; the strip to its right; clear it to black so cursor and tooltips don't smear.
on_before_toolbar:
    pushad
    mov eax, [G_WIDTH]
    cmp eax, FRONT_W
    jle .skip
    sub esp, 16 + 100           ; RECT, then DDBLTFX
    mov ebx, esp                ; RECT
    lea edx, [esp+16]           ; DDBLTFX
    mov edi, edx
    mov ecx, 25
    xor eax, eax
    rep stosd
    mov dword [edx], 100        ; dwSize; dwFillColor (+0x50) stays 0
    mov dword [ebx], FRONT_W
    mov dword [ebx+4], 0
    mov eax, [G_WIDTH]
    mov [ebx+8], eax
    mov dword [ebx+12], TOOLBAR_H
    mov eax, [DISPLAY+D_BACK]
    test eax, eax
    jz .free
    push edx
    push DDBLT_COLORFILL_WAIT
    push 0
    push 0
    push ebx
    push eax
    mov ecx, [eax]
    call [ecx+DDS_BLT]
.free:
    add esp, 16 + 100
.skip:
    popad
    mov ecx, 0x5D19A0
    ret

; Replaces "call SPRITE_BLIT" for the toolbar background (0x419ABC, always
; called with 0, 0, 0xFF, 1). Above 640 wide, draw the image as left part,
; tiled filler, and right part anchored to the screen edge, by narrowing the
; display clip rect (DISPLAY+0..+0xC = x, y, w, h) that the blit honours.
on_toolbar_bg:
    mov eax, [G_WIDTH]
    sub eax, FRONT_W
    jg .wide
    jmp SPRITE_BLIT
.wide:
    push ebp
    push esi
    push edi
    push ebx
    mov esi, ecx                ; sprite
    mov ebp, eax                ; extra width
    push dword [DISPLAY+12]     ; save clip
    push dword [DISPLAY+8]
    push dword [DISPLAY+4]
    push dword [DISPLAY]
    mov ecx, esi                ; whole image at 0,0 with the game's clip
    push 1
    push 0xFF
    push 0
    push 0
    call SPRITE_BLIT
    mov edi, TB_SPLIT           ; filler from TB_SPLIT to TB_SPLIT + extra
    lea ebx, [ebp+TB_SPLIT]
.tile:
    cmp edi, ebx
    jge .right
    mov eax, ebx
    sub eax, edi
    cmp eax, TB_TILE_W
    jle .clip
    mov eax, TB_TILE_W
.clip:
    mov [DISPLAY], edi
    mov dword [DISPLAY+4], 0
    mov [DISPLAY+8], eax
    mov dword [DISPLAY+12], TOOLBAR_H
    mov ecx, esi
    push 1
    push 0xFF
    push 0
    lea eax, [edi-TB_TILE_SRC]
    push eax
    call SPRITE_BLIT
    add edi, TB_TILE_W
    jmp .tile
.right:
    mov [DISPLAY], ebx          ; right part, shifted by the extra width
    mov dword [DISPLAY+4], 0
    mov dword [DISPLAY+8], FRONT_W - TB_SPLIT
    mov dword [DISPLAY+12], TOOLBAR_H
    mov ecx, esi
    push 1
    push 0xFF
    push 0
    push ebp
    call SPRITE_BLIT
    pop dword [DISPLAY]         ; restore clip
    pop dword [DISPLAY+4]
    pop dword [DISPLAY+8]
    pop dword [DISPLAY+12]
    pop ebx
    pop edi
    pop esi
    pop ebp
    ret 16

; Replaces "mov edi, 0x259" (0x419C46): x of slot 0, the rightmost toolbar
; slot. Shift the slots with the right part of the toolbar.
on_toolbar_slots:
    mov edi, [G_WIDTH]
    sub edi, FRONT_W
    jg .w
    xor edi, edi
.w: add edi, 0x259
    ret

; Entry of Toolbar_Click(x, y) (0x419D80). Map screen x back to the 640
; layout, then run the displaced "mov eax, [esp+8]; push ebx".
on_toolbar_click:
    call remap_toolbar_x
    mov eax, [esp+8]
    push ebx
    jmp 0x419D85

; Entry of Toolbar_Tooltip(x, y, buf) (0x41A0B0). Same mapping, then the
; displaced "sub esp, 4; mov ecx, -1".
on_toolbar_tip:
    call remap_toolbar_x
    sub esp, 4
    mov ecx, -1
    jmp 0x41A0B8

; Right-aligned HUD items laid out for 640: shift them by the extra width.
; Season icon: drawn at 0x27F - width, y 0x2E (0x40BF76), dirty rect up to
; x 0x280 (0x40BF9B/0x40BFA2), hover zone x 0x258..0x280 (0x42AE5A/0x42AE6A).
; CHEAT label (cheat mode on): text at x 0x276, y 6 (0x40C4AD).

; Replaces "mov eax, 0x27F".
on_season_x:
    call extra_width
    add eax, 0x27F
    ret

; Replaces "push 0x280".
push_season_x2:
    push eax
    call extra_width
    add eax, 0x280
    jmp push_eax_tail

; Replaces "push 0x276".
push_cheat_x:
    push eax
    call extra_width
    add eax, 0x276
    jmp push_eax_tail

; Replaces "cmp eax, 0x258". Flags are the result.
cmp_season_lo:
    push edx
    mov edx, 0x258
    jmp cmp_shifted_tail

; Replaces "cmp eax, 0x280".
cmp_season_hi:
    push edx
    mov edx, 0x280
cmp_shifted_tail:               ; [esp] = saved edx, edx = 640-layout x
    push eax
    call extra_width
    add edx, eax
    pop eax
    cmp eax, edx
    pop edx                     ; pop and ret keep the flags
    ret

; Message-log tab (tab.mfb), drawn at the bottom from x 0x190 to 0x1F4 once
; the level counter 0x5E5CC0 is non-zero (0x41A76E, dirty rect 0x41A787 and
; 0x41A79C). Its click zones (0x414D48/0x414D4F, 0x4150F3/0x4150FA) test the
; same range. It sits 80 px right of centre in the 640 layout; keep that by
; shifting it by half the extra width.

; Replaces "push 0x190".
push_tab_x1:
    push eax
    call half_extra_width
    add eax, 0x190
    jmp push_eax_tail

; Replaces "push 0x1F4".
push_tab_x2:
    push eax
    call half_extra_width
    add eax, 0x1F4
    jmp push_eax_tail

; Replaces "cmp eax, 0x190". Flags are the result.
cmp_tab_lo:
    push edx
    mov edx, 0x190
    jmp cmp_half_tail

; Replaces "cmp eax, 0x1F4".
cmp_tab_hi:
    push edx
    mov edx, 0x1F4
cmp_half_tail:                  ; [esp] = saved edx, edx = 640-layout x
    push eax
    call half_extra_width
    add edx, eax
    pop eax
    cmp eax, edx
    pop edx                     ; pop and ret keep the flags
    ret

; Replaces "call SPRITE_BLIT" for the stone filler after the last icon in
; the bottom panel (0x41A714, ecx = sprite 0x4EEBC4). The icons already run
; to g_width, but the filler is one image drawn once; repeat it until the
; screen edge. At 640 wide the first draw already reaches the edge.
on_panel_fill:
    push ebp
    push esi
    push edi
    push ebx
    mov esi, ecx
    mov ebp, [esp+20]           ; x
    mov ebx, [esp+24]           ; y
    mov edi, [esp+28]           ; frame
.again:
    push dword [esp+32]         ; flag
    push edi
    push ebx
    push ebp
    mov ecx, esi
    call SPRITE_BLIT
    mov eax, [esi+0x44]         ; image width
    cmp eax, 16
    jl .done
    add ebp, eax
    cmp ebp, [G_WIDTH]
    jl .again
.done:
    pop ebx
    pop edi
    pop esi
    pop ebp
    ret 16

; WASD camera scrolling. The window procedure already maps the arrow keys
; to the scroll flags 0x484520 (up), 0x484524 (down), 0x484528 (left) and
; 0x48452C (right) through two jump tables: key down at 0x403F5F (vk - 0x25,
; 0x99 entries) and key up at 0x405493 (vk - 0x10, 0x19 entries). ebx holds
; the virtual-key code at both. Translate W/A/S/D to the arrow codes for the
; table lookup only, leaving ebx alone.

; Jumped to from 0x403F5F; replaces "lea eax, [ebx-0x25]; cmp eax, 0x98".
on_key_down:
    call wasd_to_arrow
    sub eax, 0x25
    cmp eax, 0x98
    jmp 0x403F67

; Jumped to from 0x405493; replaces "lea eax, [ebx-0x10]; cmp eax, 0x18".
on_key_up:
    call wasd_to_arrow
    sub eax, 0x10
    cmp eax, 0x18
    jmp 0x405499

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

; ---------------------------------------------------------------- helpers

; eax = half of extra_width.
half_extra_width:
    call extra_width
    shr eax, 1
    ret

; eax = how much wider than 640 the display is (0 if not wider).
extra_width:
    mov eax, [G_WIDTH]
    sub eax, FRONT_W
    jg .done
    xor eax, eax
.done:
    ret

; Finishes a stub that replaced a 5-byte "push imm32": the stack holds the
; saved eax and then the return address, and eax holds the value to push.
; Leave the value where the return address was, as if pushed, and return.
push_eax_tail:
    xchg eax, [esp+4]           ; [esp+4] = value, eax = return address
    xchg eax, [esp]             ; [esp] = return address, eax = saved eax
    ret

; Called first thing from a hooked function entry, so the caller's x
; argument is at [esp+8] here. Right part: subtract the extra width.
; Filler: a dead x. Preserves registers except flags.
remap_toolbar_x:
    push eax
    mov eax, [G_WIDTH]
    sub eax, FRONT_W
    jle .done
    add eax, TB_SPLIT
    cmp [esp+12], eax
    jl .mid
    sub eax, TB_SPLIT
    sub [esp+12], eax
    jmp .done
.mid:
    cmp dword [esp+12], TB_SPLIT
    jl .done
    mov dword [esp+12], TB_DEAD_X
.done:
    pop eax
    ret

sync_mode:
    push dword [VIEW_MODE]
    push dword [MENU_ACTIVE]
    call sync_for
    add esp, 8
    ret

; sync_for(menu_active, view_mode), cdecl. The one rule for the display size:
; 640x480 in states 0 and 1, and in state 2 while the pause menu is open or
; the briefing is showing; mission size otherwise in state 2. Videos (state 3,
; view mode 5) manage the mode themselves, so leave it alone.
sync_for:
    mov eax, [G_SCREEN]
    cmp eax, 2
    ja .done
    jb .front
    cmp dword [esp+8], 5
    je .done
    cmp dword [esp+4], 0
    jne .front
    cmp dword [esp+8], 4
    je .front
    push dword [mission_h]
    push dword [mission_w]
    jmp .set
.front:
    push FRONT_H
    push FRONT_W
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
    ; The map view only repaints dirty areas, so after the clear it would
    ; leave black patches (flickering between the two buffers) until the
    ; camera moves. Ask for a full repaint, as SetViewMode does.
    call REQUEST_REDRAW
    pop ebx
.ret:
    ret
