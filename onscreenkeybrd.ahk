; ==============================================================================
; On-Screen Keyboard --  Version date: 7-27-2026  
; AHK Forums    https://www.autohotkey.com/boards/viewtopic.php?f=83&t=139991
; GitHub        https://github.com/kunkel321/OnScreenKeyboard
; Based on riginal On-Screen Keyboard by Jon
; https://autohotkey.com/docs/scripts/KeyboardOnScreen.htm
; Converted to AHK v2 by kunkel321 using Claude AI. 
; Code also reworked with ChatGPT.
;
; This script creates a mock keyboard at the bottom of your screen that shows
; the keys you are pressing in real time. It helps with learning to touch-type
; by not having to look at the physical keyboard. It might also be useful as 
; an on-screen display for screencasts(?) The keyboard appearance can be
; customized. You can hide/show it via the tray menu.  Drag to move.
; Ctrl+Alt+K show/hide; Alt+arrow / Alt+wheel transparency
; ==============================================================================

#SingleInstance
#Requires AutoHotkey v2+
; Allow a key's handler to re-enter (e.g. a fast re-press arriving during the brief
; restrike blink) instead of silently discarding the press. Handlers are non-blocking,
; so a few concurrent threads are cheap.
#MaxThreadsPerHotkey 3
#MaxThreads 20

; 7-25-2026 Add k_CondensedMode switch: shorter key height for a compact screencast-friendly layout; default false keeps full physical-keyboard proportions for touch-typing practice.
; Condense only the five main rows (30→20px)
; F-row shrinks slightly and its heights derive from the full key height so labels never get crushed. Width, spacing, and font unchanged.

; 7-27-2026 Add hook-front jumping: OSK's low-level hooks are force-reinstalled so
; they sit FIRST in the system's hook chain. Windows calls the most recently
; installed hook first, and a hook that SUPPRESSES a key (e.g. ScreenSnip's
; Alt+. / Alt+, hotkeys) never passes the event down the chain -- which is why
; combos eaten by other scripts never lit up here. With our passthrough (~*) hooks
; in front, we highlight the key and hand it down the chain; the suppressing app
; still works exactly as before. See JumpHooksToFront() near the bottom of the
; auto-execute section.
; (A Raw Input rewrite was tried first and FAILED: hook-suppressed keys do not
; reach WM_INPUT listeners on modern Windows -- raw input delivery happens after
; the hook chain, despite widespread folklore to the contrary. Empirically
; verified on this machine: suppressed key-downs vanished, unsuppressed key-ups
; arrived. Don't go down that road again.)

TraySetIcon("shell32.dll",45) ; Icon of a brownish square with a key image.
A_IconTip := "On-Screen Keyboard" (A_IsAdmin ? " (admin)" : "")  ; elevation at a glance
^Esc::ExitApp ; Ctrl+Esc to kill script

;---- Configuration Section
k_FontSize := 10
k_FontName := "Verdana"  ; Leave empty to use system default
k_FontStyle := "Bold"    ; Examples: "Italic Underline"

; Condensed mode: shrink the key HEIGHT only, so the whole keyboard takes up less
; vertical space. Width, spacing, font, and labels are identical in both modes -- only
; the rows get shorter.
;   false -> FULL height. Keys are ~square, close to a real keyboard's proportions. Best
;            when using the tool to PRACTICE TOUCH-TYPING: it mirrors the feel and footprint
;            of the physical keyboard, so muscle memory transfers.
;   true  -> CONDENSED. The five main rows are noticeably shorter; the F-row shrinks only
;            slightly (its Esc / F10 / Del labels are the tightest fit). Best for SCREENCASTS,
;            where a short overlay stays out of the way of whatever you're recording.
k_CondensedMode := true

; Key colors. Use 6-digit RGB hex values without the leading #.
; Text controls are used instead of real Button controls because they allow
; reliable background-color changes for clearer visual feedback.
k_KeyBackColor := "E6E6E6"       ; normal key/button fill
k_KeyActiveColor := "ff3d3d"     ; held/pressed key fill
k_MouseBackColor := "E6E6E6"     ; normal mouse button/wheel fill
k_MouseActiveColor := "1048ff"   ; mouse button hold / wheel flash fill
k_KeyTextColor := "000000"       ; key label text

; Release fade: when a key is let go, its highlight steps back down to the normal
; fill through a precomputed color ramp instead of snapping off. The ramp runs from
; the ACTIVE color (step 1) to the NORMAL color (last step); no new colors needed.
;   k_FadeSteps    = number of colors in the ramp, endpoints included.
;                    Set to 1 to disable the fade (instant off, original behavior).
;                    More steps = smoother; fewer = chunkier.
;   k_FadeDuration = total time (ms) for a released key to travel the whole ramp.
k_FadeSteps := 12
k_FadeDuration := 400
; Restrike blink: when a key is pressed again while it is still fading out (e.g. the
; double "o" in "book"), snap it to the normal color for this many ms before
; re-highlighting. Without it, the key jumps from a partly-faded tint straight back
; to full active, so the two strikes read as one long press. Set to 0 to disable.
k_RestrikeBlinkMs := 45

; Mouse gestures that hide the keyboard (Ctrl+Alt+K or the tray item brings it back).
; Set either to false to disable that gesture.
k_DblClickHides := true
k_RightClickHides := false
; Per-step dwell = the timer period. Guard against divide-by-zero when fade is off.
k_FadeStepMs := (k_FadeSteps > 1) ? Max(15, Round(k_FadeDuration / (k_FadeSteps - 1))) : 0
; Precompute the two ramps once (keys and mouse buttons have different fills).
k_KeyFadeColors := BuildFadeGradient(k_KeyActiveColor, k_KeyBackColor, k_FadeSteps)
k_MouseFadeColors := BuildFadeGradient(k_MouseActiveColor, k_MouseBackColor, k_FadeSteps)

; Global show/hide toggle. The keyboard is a passive display that runs while you
; type, so a bare key would clash with normal typing -- use a modifier combo.
; Change k_ToggleHotkey if Ctrl+Alt+K collides with something (keep
; k_ToggleHotkeyLabel in sync; it's only the text shown in the tray menu).
k_ToggleHotkey := "^!k"              ; ^ = Ctrl, ! = Alt  -> Ctrl+Alt+K
k_ToggleHotkeyLabel := "Ctrl+Alt+K"

k_MenuItemHide := "Hide Keyboard -- " . k_ToggleHotkeyLabel
k_MenuItemShow := "Show Keyboard -- " . k_ToggleHotkeyLabel

k_Monitor := ""  ; Leave empty for primary monitor, or specify 2, 3, etc.

; Transparency: Alt+Up / Alt+Down and Alt+WheelUp / Alt+WheelDown adjust the
; keyboard's overall opacity, but only while the keyboard window is focused.
; Up / WheelUp = more opaque; Down / WheelDown = more see-through. Flip the sign
; of k_TransparencyStep at registration if you prefer the opposite direction.
k_Transparency := 255       ; current alpha: 255 = fully opaque, lower = more transparent
k_TransparencyStep := 15    ; amount each keypress / wheel notch changes the alpha
k_TransparencyMin := 30     ; floor so the window never fades away completely

; OSK will reestablish keyboard hooks with this frequency (millisecs) to ensre that
; other apps don't "eat" key-combos.  This is useful for screencasts.  Rehooks only
; occur if/when the OSK gui is not hidden. 
K_HookFrequency := 3000

;---- Calculate dimensions based on font size
k_KeyWidth := k_FontSize * 3
k_KeyMargin := Floor(k_FontSize / 6)
k_SpacebarWidth := k_FontSize * 25
k_KeyWidthHalf := Floor(k_KeyWidth / 2)
k_ModifierWidth := k_KeyWidth + 20  ; Extra width for modifier keys
k_ShiftWidth := k_KeyWidth + 40     ; Wider for Shift
k_Row3Offset := k_KeyWidthHalf + 18 ; Offset for third row (ASDF...)

; ---- Key HEIGHT -- the only thing k_CondensedMode changes ----
; Main rows (number, QWERTY, ASDF, Shift, modifier/Space). The layout flows each row just
; below the previous one and reads positions back with GetPos, so simply making the keys
; shorter packs the whole GUI tighter -- no other spacing math needs touching. Drop
; k_KeyHeightCondensed toward Floor(k_FontSize * 1.8) if you want it shorter still; below
; roughly that the labels start to feel cramped at this font size.
k_KeyHeightFull      := k_FontSize * 3         ; 30 at font 10 -- ~physical-keyboard height
k_KeyHeightCondensed := Floor(k_FontSize * 1.9)  ; 20 -- about a third shorter, still legible
k_KeyHeight := k_CondensedMode ? k_KeyHeightCondensed : k_KeyHeightFull

; F-row keys: same WIDTH as normal keys, but SHORTER, with a smaller font so the longer
; labels (Esc, F10, F11, F12, Del) still fit. BOTH F-row heights are fractions of the FULL
; key height (never the condensed one), so the F-row shrinks only a little in condensed mode
; and its labels are never crushed. Lower the 0.5 toward Floor(k_KeyHeightFull / 2) for an
; even shorter row.
k_FKeyFontSize        := k_FontSize - 2                 ; smaller font just for the F-row
k_FKeyHeightFull      := Floor(k_KeyHeightFull * 0.6)   ; ~18 -- normal F-row height
k_FKeyHeightCondensed := Floor(k_KeyHeightFull * 0.5)   ; ~15 -- only a touch shorter
k_FKeyHeight := k_CondensedMode ? k_FKeyHeightCondensed : k_FKeyHeightFull

;---- Create the GUI
; The title is never shown (the window is caption-less) but it gives other AC2 tools
; a stable handle to find this window if they want to PostMessage it directly instead
; of broadcasting. See the "external highlight" receiver further below.
MyGui := Gui()
MyGui.Title := "OnScreenKeyboardDisplay"
MyGui.Opt("-Caption +ToolWindow")
MyGui.SetFont("s" . k_FontSize . " " . k_FontStyle, k_FontName)

TransColor := "F1ECED"
MyGui.BackColor := TransColor

;---- Button size and position options
k_KeySize := "w" . k_KeyWidth . " h" . k_KeyHeight
k_Position := "x+" . k_KeyMargin . " " . k_KeySize

; F-row: normal width, shorter height. First key flush-left; rest flow to the right.
k_FKeySize := "w" . k_KeyWidth . " h" . k_FKeyHeight
k_FKeyFirst := "xm " . k_FKeySize
k_FKeyNext := "x+" . k_KeyMargin . " " . k_FKeySize

;---- Maps to store key control references and each control's normal color
buttons := Map()
buttonNormalColors := Map()
fadingKeys := Map()   ; keys currently fading out: buttonKey -> {colors, idx}

; Row 0: F-row (Esc, F1-F12, Del). Added FIRST so it sits at the top; the number
; row below flows down from it. Uses a smaller font, restored right after.
MyGui.SetFont("s" . k_FKeyFontSize . " " . k_FontStyle, k_FontName)
AddKey("Escape", k_FKeyFirst, "Esc")
for key in ["F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"]
    AddKey(key, k_FKeyNext, key)
AddKey("Delete", k_FKeyNext, "Del")
MyGui.SetFont("s" . k_FontSize . " " . k_FontStyle, k_FontName)

; Row 1: Number keys (now flows below the F-row via y+margin)
AddKey("1", "section " . k_KeySize . " xm+" . k_KeyWidth . " y+" . k_KeyMargin, "1")
AddKey("2", k_Position, "2")
AddKey("3", k_Position, "3")
AddKey("4", k_Position, "4")
AddKey("5", k_Position, "5")
AddKey("6", k_Position, "6")
AddKey("7", k_Position, "7")
AddKey("8", k_Position, "8")
AddKey("9", k_Position, "9")
AddKey("0", k_Position, "0")
AddKey("-", k_Position, "-")
AddKey("=", k_Position, "=")
AddKey("Backspace", k_Position, "BS")

; Row 2: QWERTY row
AddKey("Tab", "xm y+" . k_KeyMargin . " h" . k_KeyHeight . " w" . k_ModifierWidth, "Tab")
for key in ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "[", "]", "\"]
    AddKey(key, k_Position, key)

; Row 3: ASDF row
AddKey("A", "xs+" . k_Row3Offset . " y+" . k_KeyMargin . " " . k_KeySize, "A")
for key in ["S", "D", "F", "G", "H", "J", "K", "L", ";", "'"]
    AddKey(key, k_Position, key)
AddKey("Enter", "x+" . k_KeyMargin . " h" . k_KeyHeight . " w" . k_ShiftWidth, "Enter")

; Row 4: Shift row
AddKey("Shift", "xm y+" . k_KeyMargin . " h" . k_KeyHeight . " w" . k_ShiftWidth, "Shift")
for key in ["Z", "X", "C", "V", "B", "N", "M", ",", ".", "/"]
    AddKey(key, k_Position, key)

; Row 5: Modifiers and Spacebar
AddKey("Ctrl", "xm y+" . k_KeyMargin . " h" . k_KeyHeight . " w" . k_ModifierWidth, "Ctrl")
AddKey("Win", "h" . k_KeyHeight . " x+" . k_KeyMargin . " w" . k_ModifierWidth, "Win")
AddKey("Alt", "h" . k_KeyHeight . " x+" . k_KeyMargin . " w" . k_ModifierWidth, "Alt")
AddKey("Space", "h" . k_KeyHeight . " x+" . k_KeyMargin . " w" . k_SpacebarWidth, "Space")


; Row 4/5 add-on: Arrow keys, placed to the right of the spacebar.
; Arrow key names are the AHK key names: Up, Left, Down, Right.
; The button text uses arrow glyphs, while the map keys use normal key names.
buttons["Space"].GetPos(&k_SpaceX, &k_SpaceY, &k_SpaceW, &k_SpaceH)
buttons["Z"].GetPos(, &k_Row4Y)
k_ArrowGap := k_KeyMargin * 4
k_ArrowX := k_SpaceX + k_SpaceW + k_ArrowGap
k_ArrowYTop := k_Row4Y
k_ArrowYBottom := k_SpaceY
AddKey("Up", "x" . (k_ArrowX + k_KeyWidth + k_KeyMargin) . " y" . k_ArrowYTop . " " . k_KeySize, "▲")
AddKey("Left", "x" . k_ArrowX . " y" . k_ArrowYBottom . " " . k_KeySize, "◀")
AddKey("Down", "x" . (k_ArrowX + k_KeyWidth + k_KeyMargin) . " y" . k_ArrowYBottom . " " . k_KeySize, "▼")
AddKey("Right", "x" . (k_ArrowX + (k_KeyWidth + k_KeyMargin) * 2) . " y" . k_ArrowYBottom . " " . k_KeySize, "▶")

; Mouse add-on: simple visual representation of mouse buttons and wheel.
; These are not clickable typing buttons. They just light up when the physical mouse is used.
k_MouseX := k_ArrowX + (k_KeyWidth + k_KeyMargin) * 3 + k_KeyMargin * 2
; Line the mouse block up with the number + QWERTY rows (not the short F-row),
; so it keeps the same vertical relationship it had before the F-row existed.
buttons["1"].GetPos(, &k_NumRowY)
k_MouseY := k_NumRowY
k_MouseButtonW := k_KeyWidth + 10
k_MouseButtonH := k_KeyHeight * 2 + k_KeyMargin
k_WheelW := Max(28, k_KeyWidth)
k_WheelH := k_KeyHeight
AddKey("LButton", "x" . k_MouseX . " y" . k_MouseY . " w" . k_MouseButtonW . " h" . k_MouseButtonH, "L", k_MouseBackColor)
AddKey("WheelUp", "x" . (k_MouseX + k_MouseButtonW + k_KeyMargin) . " y" . k_MouseY . " w" . k_WheelW . " h" . k_WheelH, "▲", k_MouseBackColor)
AddKey("WheelDown", "x" . (k_MouseX + k_MouseButtonW + k_KeyMargin) . " y" . (k_MouseY + k_WheelH + k_KeyMargin) . " w" . k_WheelW . " h" . k_WheelH, "▼", k_MouseBackColor)
AddKey("RButton", "x" . (k_MouseX + k_MouseButtonW + k_WheelW + k_KeyMargin * 2) . " y" . k_MouseY . " w" . k_MouseButtonW . " h" . k_MouseButtonH, "R", k_MouseBackColor)

;---- Show the GUI
MyGui.Show()
k_IsVisible := true

;---- Add drag-to-move functionality for borderless window
OnMessage(0x0201, WM_LBUTTONDOWN)

;---- Double-click to hide. Windows does NOT resend WM_LBUTTONDOWN for the second
; click of a double-click -- it substitutes WM_LBUTTONDBLCLK -- so that is the
; message to watch. 0x00A3 is the non-client twin, monitored too since this window
; fakes a caption drag. (See k_DblClickHides.)
OnMessage(0x0203, WM_LBUTTONDBLCLK)   ; WM_LBUTTONDBLCLK
OnMessage(0x00A3, WM_LBUTTONDBLCLK)   ; WM_NCLBUTTONDBLCLK

;---- Right-click anywhere on the keyboard hides it (see k_RightClickHides)
OnMessage(0x0204, WM_RBUTTONDOWN)  ; WM_RBUTTONDOWN

;---- Block F10 / lone-Alt from opening the window's (nonexistent) menu, which
; otherwise traps the GUI in menu-modal mode: the F10 highlight sticks, other
; F-keys stop registering, and stray keys beep. Only matters when the GUI is
; focused (never during normal use), but the fix is cheap and clean.
OnMessage(0x0112, WM_SYSCOMMAND)  ; WM_SYSCOMMAND

;---- External highlight channel (for other AC2 tools, e.g. ScreenSnip).
; Some tools suppress a mouse button to do their own thing (ScreenSnip suppresses
; RButton during a Ctrl+RClick-drag snip so no context menu appears). A suppressed
; button never reaches this script's mouse hook, so ~*RButton can't light it up. The
; fix: the other tool tells us directly. It PostMessages this registered message with
;   wParam = 1 to light a button, 0 to release/fade it
;   lParam = 1 for LButton, 2 for RButton   (matches VK_LBUTTON / VK_RBUTTON)
; RegisterWindowMessage returns the SAME id in every process for a given string, so the
; sender just computes it the same way -- no shared header or hard-coded number needed.
k_ExtHighlightMsg := DllCall("RegisterWindowMessage", "Str", "AHK_OSK_MouseHighlight", "UInt")
OnMessage(k_ExtHighlightMsg, OnExternalHighlight)

;---- Get GUI dimensions and ID
k_ID := MyGui.Hwnd
WinGetPos(, , &k_WindowWidth, &k_WindowHeight, "ahk_id " k_ID)

;---- Position at bottom center of screen
if k_Monitor = ""
    MonitorGetWorkArea(1, &MonLeft, &MonTop, &MonRight, &MonBottom)
else
    MonitorGetWorkArea(k_Monitor, &MonLeft, &MonTop, &MonRight, &MonBottom)

; Calculate X position (center horizontally)
k_WindowX := MonRight - MonLeft - k_WindowWidth
k_WindowX := k_WindowX / 2 + MonLeft

; Calculate Y position (bottom of monitor)
k_WindowY := MonBottom - k_WindowHeight

WinMove(k_WindowX, k_WindowY, , , "ahk_id " k_ID)
WinSetAlwaysOnTop(true, "ahk_id " k_ID)

; NOTE ON DOWN/UP PAIRS: every key registers BOTH a down and an "up" hotkey, and
; each handler returns immediately. Earlier versions used a single handler that sat
; in KeyWait() until release -- but AHK pauses an interrupted thread until the
; interrupting one finishes, so during rollover typing (e.g. "there", where R goes
; down before E comes up) the R handler's KeyWait would trap the E handler. E never
; got to start its fade, and its re-press was discarded by #MaxThreadsPerHotkey.
; Non-blocking down/up handlers avoid the whole thread-stack problem.

;---- Register all ASCII character hotkeys (45 to 93: - through ])
Loop 49 {
    k_ASCII := 44 + A_Index
    k_char := Chr(k_ASCII)
    k_char := StrUpper(k_char)
    ; Skip characters that must NOT be registered as their own hotkeys:
    ;   ^ ~ , <  -> hotkey-SYNTAX characters (Ctrl, passthrough, separator, and the
    ;               left/right-modifier prefixes), plus > for symmetry.
    ;   : ? @    -> SHIFTED glyphs that share a physical key with ; / 2 . Registering
    ;               e.g. ~*? makes AHK fire IT (not ~*/) on Shift+/, because a
    ;               shift-required variant is the more specific match. It then resolves
    ;               to a "?" button that doesn't exist, so / never lights up under Shift.
    ;               Skipping them lets ~*/ ~*; ~*2 fire for the shifted presses too,
    ;               lighting the correct on-screen key.
    ; (< and > -- the shifted glyphs of , and . -- are already covered by the syntax set.)
    if !InStr("<>^~,:?@", k_char) {
        Hotkey("~*" . k_char, KeyPress)
        Hotkey("~*" . k_char . " up", KeyRelease)
    }
}

;---- Register modifier key hotkeys
for key in ["LShift", "RShift", "LCtrl", "RCtrl", "LAlt", "RAlt", "LWin", "RWin"] {
    Hotkey("~*" . key, KeyPress)
    Hotkey("~*" . key . " up", KeyRelease)
}

;---- Register special key hotkeys
for key in ["Backspace", "Space", "Tab", "Enter", ",", "'"] {
    Hotkey("~*" . key, KeyPress)
    Hotkey("~*" . key . " up", KeyRelease)
}

;---- Register arrow key hotkeys
for key in ["Up", "Left", "Down", "Right"] {
    Hotkey("~*" . key, KeyPress)
    Hotkey("~*" . key . " up", KeyRelease)
}

;---- Register F-row hotkeys (F1-F12 and Del light up like normal keys)
for key in ["F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12", "Delete"] {
    Hotkey("~*" . key, KeyPress)
    Hotkey("~*" . key . " up", KeyRelease)
}

;---- Register mouse hotkeys
for key in ["LButton", "RButton"] {
    Hotkey("~*" . key, KeyPress)
    Hotkey("~*" . key . " up", KeyRelease)
}
for key in ["WheelUp", "WheelDown"]
    Hotkey("~*" . key, MouseWheelPress)

;---- Register Esc key: lights up the on-screen Esc AND hides GUI when active.
; Passthrough (~*) so Esc still reaches other apps. ^Esc::ExitApp stays in effect
; because that more-specific variant wins for Ctrl+Esc.
Hotkey("~*Esc", KeyPress)
Hotkey("~*Esc up", EscRelease)

;---- Register the global show/hide toggle (works even while the keyboard is hidden)
Hotkey(k_ToggleHotkey, ToggleKeyboard)

;---- Register transparency hotkeys, live ONLY while the keyboard window is focused.
; HotIf gates them, so Alt+Up/Down and Alt+Wheel behave normally everywhere else.
HotIf(IsKbFocused)
Hotkey("!Up",        AdjustTransparency.Bind( k_TransparencyStep))
Hotkey("!Down",      AdjustTransparency.Bind(-k_TransparencyStep))
Hotkey("!WheelUp",   AdjustTransparency.Bind( k_TransparencyStep))
Hotkey("!WheelDown", AdjustTransparency.Bind(-k_TransparencyStep))
HotIf()  ; reset to global context for anything registered afterward

;---- HOOK-FRONT JUMPING: the fix for other apps "eating" key combos. ----
; All of this script's display hotkeys are ~* passthrough, so being FIRST in the
; low-level hook chain is pure win: we see and highlight every physical key, then
; pass the event down the chain, where a suppressing script (ScreenSnip et al.)
; can still eat it for its own purposes. Windows calls the most recently installed
; hook first, so "jump to the front" = force our hooks to reinstall. Re-asserted on
; a timer because any app that installs a hook later takes the front spot back.
; Cost of the force-reinstall: a microsecond gap where our hook is absent; a key
; landing exactly in that gap misses its highlight. At this cadence, negligible.
; (Bonus: also self-heals if Windows silently removes a hook for responding too
; slowly under load, which it is documented to do.)
JumpHooksToFront() {
    global k_IsVisible
    ; While hidden, nobody can see the highlights, so front-of-chain position is
    ; worthless -- and every force-reinstall carries a microsecond gap where a
    ; keystroke could slip past unhighlighted. Skip the churn until shown again;
    ; ShowKeyboard() calls us immediately on unhide so there's no 3-second lag.
    if !k_IsVisible
        return
    InstallKeybdHook(true, true)   ; true, true = install + FORCE reinstall
    InstallMouseHook(true, true)
}
JumpHooksToFront()
SetTimer(JumpHooksToFront, K_HookFrequency)

;---- Tray menu setup
TrayMenu := A_TrayMenu
; Grayed status line at the top: shows elevation state right in the menu. (The
; A_IconTip set near the top of the script shows the same info as the tray icon's
; HOVER tooltip; this menu line is the click-visible twin.) Disabled items still
; need a callback in v2, hence the no-op.
k_StatusLine := "On-Screen Keyboard " (A_IsAdmin ? "(admin)" : "(NOT admin)")
TrayMenu.Insert("1&", k_StatusLine, (*) => "")
TrayMenu.Disable(k_StatusLine)
TrayMenu.Add(k_MenuItemHide, ToggleKeyboard)
TrayMenu.Default := k_MenuItemHide

return

;---- GUI key helpers
AddKey(buttonKey, options, label := "", normalColor := "") {
    global MyGui, buttons, buttonNormalColors, k_KeyBackColor, k_KeyTextColor

    if label = ""
        label := buttonKey
    if normalColor = ""
        normalColor := k_KeyBackColor

    ; +Border keeps each key visibly separate even when it is not active.
    ; +0x200 vertically centers the label inside the Text control.
    ctrl := MyGui.Add("Text", options . " Center +Border +0x200 Background" . normalColor . " c" . k_KeyTextColor, label)
    buttons[buttonKey] := ctrl
    buttonNormalColors[buttonKey] := normalColor
    return ctrl
}

SetKeyActive(buttonKey, isActive := true, isMouse := false) {
    global buttons, buttonNormalColors, fadingKeys, k_KeyActiveColor, k_MouseActiveColor
    global k_KeyBackColor, k_RestrikeBlinkMs

    if !buttons.Has(buttonKey)
        return

    normalColor := buttonNormalColors.Has(buttonKey) ? buttonNormalColors[buttonKey] : k_KeyBackColor

    if isActive {
        ; Re-pressed while still fading (double letters like the "oo" in "book").
        ; Delete from the fade map FIRST so the shared FadeTick timer can't repaint
        ; over the blink, then flash the normal color so the second strike reads as
        ; a distinct press instead of merging into the first one's lingering glow.
        if fadingKeys.Has(buttonKey) {
            fadingKeys.Delete(buttonKey)
            if (k_RestrikeBlinkMs > 0) {
                PaintKey(buttonKey, normalColor)
                Sleep(k_RestrikeBlinkMs)   ; brief, and the keystroke itself already passed through
            }
        }
        color := isMouse ? k_MouseActiveColor : k_KeyActiveColor
    } else {
        color := normalColor
    }

    PaintKey(buttonKey, color)
}

;---- Paint a key's background and force the repaint. Themed Text controls don't
; always refresh on a background change, hence the belt-and-suspenders redraw.
PaintKey(buttonKey, color) {
    global buttons
    if !buttons.Has(buttonKey)
        return
    ctrl := buttons[buttonKey]
    ctrl.Opt("Background" . color)
    try ctrl.Redraw()
    try DllCall("RedrawWindow", "Ptr", ctrl.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x0105)
}

;---- Build a `steps`-long color ramp from activeHex down to normalHex (inclusive).
; Returns bare "RRGGBB" strings so they drop straight into Gui Background options.
; A straight two-color lerp -- unlike the 3-point white/color/black swatch gradient.
; Function was inspired by ColorGradient() by Lateralus138 and Teadrinker.
BuildFadeGradient(activeHex, normalHex, steps) {
    grad := []
    if (steps <= 1) {
        grad.Push(normalHex)   ; fade disabled: ramp is just the normal color
        return grad
    }
    aR := Integer("0x" . SubStr(activeHex, 1, 2)), nR := Integer("0x" . SubStr(normalHex, 1, 2))
    aG := Integer("0x" . SubStr(activeHex, 3, 2)), nG := Integer("0x" . SubStr(normalHex, 3, 2))
    aB := Integer("0x" . SubStr(activeHex, 5, 2)), nB := Integer("0x" . SubStr(normalHex, 5, 2))
    Loop steps {
        t := (A_Index - 1) / (steps - 1)   ; 0 at active end, 1 at normal end
        r := Round(aR + (nR - aR) * t)
        g := Round(aG + (nG - aG) * t)
        b := Round(aB + (nB - aB) * t)
        grad.Push(Format("{:02X}{:02X}{:02X}", r, g, b))
    }
    return grad
}

;---- Start a released key fading toward its normal fill. idx 1 is the active color
; (already showing), so the shared timer just walks each fading key one step per tick.
StartKeyFade(buttonKey, isMouse := false) {
    global buttons, buttonNormalColors, fadingKeys, k_KeyFadeColors, k_MouseFadeColors
    global k_FadeSteps, k_FadeStepMs, k_KeyBackColor

    if !buttons.Has(buttonKey)
        return

    ; Fade disabled -> revert instantly to the key's stored normal color.
    if (k_FadeSteps <= 1) {
        PaintKey(buttonKey, buttonNormalColors.Has(buttonKey) ? buttonNormalColors[buttonKey] : k_KeyBackColor)
        return
    }

    fadingKeys[buttonKey] := { colors: (isMouse ? k_MouseFadeColors : k_KeyFadeColors), idx: 1 }
    SetTimer(FadeTick, k_FadeStepMs)   ; (re)arm the one shared fade timer
}

;---- Shared timer: advance every fading key one step toward normal; drop finished
; keys; stop the timer once nothing is fading.
FadeTick() {
    global fadingKeys, k_FadeSteps
    for key, st in fadingKeys.Clone() {   ; clone so we can delete during iteration
        st.idx += 1
        PaintKey(key, st.colors[st.idx])
        if (st.idx >= k_FadeSteps)
            fadingKeys.Delete(key)
    }
    if (fadingKeys.Count = 0)
        SetTimer(FadeTick, 0)
}

;---- Resolve A_ThisHotkey into the button key used in the `buttons` map.
; Handles the "~*" prefix, the trailing " up" on release hotkeys, modifier
; L/R variants (LShift -> Shift), and the arrow glyph labels.
ResolveButtonKey(hk) {
    thisKey := StrReplace(hk, "~", "")
    thisKey := StrReplace(thisKey, "*", "")
    thisKey := RegExReplace(thisKey, "i)\s+up$", "")   ; strip release suffix

    ; Modifiers: collapse Left/Right variants onto the single on-screen button.
    if InStr(thisKey, "Shift")
        return "Shift"
    if InStr(thisKey, "Ctrl")
        return "Ctrl"
    if InStr(thisKey, "Alt")
        return "Alt"
    if InStr(thisKey, "Win")
        return "Win"

    ; Only Esc needs remapping: its hotkey fires as "Esc" but the button is stored
    ; under "Escape". Backspace, the arrows, Delete, etc. are all stored under the same
    ; name their hotkey fires as, so they must pass through UNCHANGED -- an earlier
    ; version remapped Backspace->"BS" and the arrows->"↑←↓→", none of which exist as
    ; button keys, so those keys never highlighted.
    switch thisKey {
        case "Esc": return "Escape"   ; hotkey fires as "Esc", button is stored as "Escape"
    }
    return thisKey
}

;---- True for the mouse buttons, which use their own active/normal colors.
IsMouseKey(buttonKey) {
    return (buttonKey = "LButton" || buttonKey = "RButton"
         || buttonKey = "WheelUp" || buttonKey = "WheelDown")
}

;---- Key/button DOWN: highlight. Returns immediately -- never blocks.
KeyPress(ThisHotkey) {
    global buttons
    buttonKey := ResolveButtonKey(A_ThisHotkey)
    if buttons.Has(buttonKey)
        SetKeyActive(buttonKey, true, IsMouseKey(buttonKey))
}

;---- Key/button UP: begin the fade. Returns immediately -- never blocks.
KeyRelease(ThisHotkey) {
    global buttons
    buttonKey := ResolveButtonKey(A_ThisHotkey)
    if buttons.Has(buttonKey)
        StartKeyFade(buttonKey, IsMouseKey(buttonKey))
}

;---- Hotkey handler for mouse wheel events
MouseWheelPress(ThisHotkey) {
    global buttons

    thisKey := A_ThisHotkey
    thisKey := StrReplace(thisKey, "~*", "")

    if buttons.Has(thisKey) {
        SetKeyActive(thisKey, true, true)
        ; Wheel events have no release, so hold the flash briefly, then fade it out.
        SetTimer(() => StartKeyFade(thisKey, true), -150)
    }
}

;---- Receiver for the external highlight message (see k_ExtHighlightMsg registration).
; A sibling tool asks us to light or fade a mouse button it is about to suppress on its
; own. We route through the same SetKeyActive / StartKeyFade paths a real press uses, so
; the on-screen button behaves identically (mouse colors, fade ramp, etc.). A lit button
; stays lit until the sender posts the matching release, so it holds through a long drag.
OnExternalHighlight(wParam, lParam, *) {
    static codeToKey := Map(1, "LButton", 2, "RButton")
    if !codeToKey.Has(lParam)
        return
    buttonKey := codeToKey[lParam]
    if wParam
        SetKeyActive(buttonKey, true, IsMouseKey(buttonKey))   ; light it
    else
        StartKeyFade(buttonKey, IsMouseKey(buttonKey))         ; fade it out
}

;---- Show / hide / toggle the keyboard. All three entry points (tray item, Esc,
; and the global hotkey) route through these so k_IsVisible and the menu label
; can never drift out of sync.
ShowKeyboard() {
    global MyGui, k_IsVisible, k_MenuItemHide, k_MenuItemShow, TrayMenu
    if k_IsVisible
        return
    MyGui.Show()
    TrayMenu.Rename(k_MenuItemShow, k_MenuItemHide)
    k_IsVisible := true
    ; Hook jumps are paused while hidden (see JumpHooksToFront), so grab the front
    ; of the hook chain NOW rather than waiting up to 3s for the next timer tick.
    JumpHooksToFront()
}

HideKeyboard() {
    global MyGui, k_IsVisible, k_MenuItemHide, k_MenuItemShow, TrayMenu
    if !k_IsVisible
        return
    MyGui.Hide()
    TrayMenu.Rename(k_MenuItemHide, k_MenuItemShow)
    k_IsVisible := false
}

; (*) so it works as both a hotkey callback and a menu callback (different arg counts).
ToggleKeyboard(*) {
    global k_IsVisible
    if k_IsVisible
        HideKeyboard()
    else
        ShowKeyboard()
}

;---- Handle drag-to-move for the borderless window. The window has no title bar,
; so a plain click is redirected into Windows' caption-drag loop.
WM_LBUTTONDOWN(wParam, lParam, msg, hwnd) {
    global MyGui
    ; 0x00A1 = WM_NCLBUTTONDOWN, 2 = HTCAPTION -> lets the borderless window be dragged.
    PostMessage(0x00A1, 2, 0, , "ahk_id " MyGui.Hwnd)
}

;---- Double-click anywhere on the keyboard hides it.
; NOTE: an earlier attempt tried to detect this by timing successive WM_LBUTTONDOWN
; messages, which never worked -- Windows sends WM_LBUTTONDBLCLK instead of a second
; WM_LBUTTONDOWN, so the second click was invisible to that code. (Amusingly, a
; TRIPLE click did fire it, because click 3 arrives as a normal WM_LBUTTONDOWN and
; still fell within the double-click time of click 1.) Watching for the real
; double-click message is both correct and simpler. Triple-click still hides, since
; a triple-click contains a double-click.
WM_LBUTTONDBLCLK(wParam, lParam, msg, hwnd) {
    global MyGui, k_DblClickHides

    if (!k_DblClickHides)
        return
    if (hwnd != MyGui.Hwnd)
        return

    HideKeyboard()
    return 0
}

;---- Right-click anywhere on the keyboard hides it. No drag loop to work around
; here, so this one is straightforward. Guarded to this window; the ~*RButton
; hotkey still lights up the on-screen R button as usual.
WM_RBUTTONDOWN(wParam, lParam, msg, hwnd) {
    global MyGui, k_RightClickHides

    if (!k_RightClickHides)
        return
    if (hwnd != MyGui.Hwnd)
        return

    HideKeyboard()
    return 0
}

;---- Swallow menu activation (F10 / lone Alt) so the borderless GUI can't get
; stuck in menu-modal mode. Returning 0 (not "") suppresses default handling.
WM_SYSCOMMAND(wParam, lParam, msg, hwnd) {
    global MyGui
    if (hwnd = MyGui.Hwnd && (wParam & 0xFFF0) = 0xF100)  ; SC_KEYMENU
        return 0
}

;---- Esc RELEASE: fade the key like any other, then hide the GUI if it's active.
; The Esc key's highlight-on-down is handled by the generic KeyPress handler.
EscRelease(ThisHotkey) {
    global buttons, MyGui, k_IsVisible

    if buttons.Has("Escape")
        StartKeyFade("Escape")

    ; Preserve original behavior: Esc hides the keyboard when it's the active window.
    if WinActive("ahk_id " MyGui.Hwnd) && k_IsVisible
        HideKeyboard()
}

;---- Transparency helpers
; HotIf callback: the transparency hotkeys are live only when the keyboard is focused.
IsKbFocused(*) {
    global MyGui
    return WinActive("ahk_id " MyGui.Hwnd)
}

; Nudge the keyboard's overall opacity by delta, clamped to [k_TransparencyMin, 255].
AdjustTransparency(delta, *) {
    global MyGui, k_Transparency, k_TransparencyMin
    k_Transparency := Max(k_TransparencyMin, Min(255, k_Transparency + delta))
    if (k_Transparency >= 255)
        WinSetTransparent("Off", "ahk_id " MyGui.Hwnd)  ; fully opaque (drops layered style)
    else
        WinSetTransparent(k_Transparency, "ahk_id " MyGui.Hwnd)
}
