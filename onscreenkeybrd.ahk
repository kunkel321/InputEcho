#SingleInstance
#Requires AutoHotkey v2+

; On-Screen Keyboard (v2) -- Original by Jon
; https://autohotkey.com/docs/scripts/KeyboardOnScreen.htm
; Converted to AHK v2 by kunkel321 using Claude AI. 
; Code also reworked with ChatGPT.
; Version date: 7-10-2026  
;
; Ctrl+Alt+K show/hide; Alt+arrow / Alt+wheel transparency
; This script creates a mock keyboard at the bottom of your screen that shows
; the keys you are pressing in real time. It helps with learning to touch-type
; by not having to look at the physical keyboard. It might also be useful as 
; an on-screen display for screencasts(?) The keyboard appearance can be
; customized. You can hide/show it via the tray menu.  Drag to move.

TraySetIcon("shell32.dll",45) ; Icon of a brownish square with a key image.
^Esc::ExitApp ; Ctrl+Esc to kill script

;---- Configuration Section
k_FontSize := 10
k_FontName := "Verdana"  ; Leave empty to use system default
k_FontStyle := "Bold"    ; Examples: "Italic Underline"

; Key colors. Use 6-digit RGB hex values without the leading #.
; Text controls are used instead of real Button controls because they allow
; reliable background-color changes for clearer visual feedback.
k_KeyBackColor := "E6E6E6"       ; normal key/button fill
k_KeyActiveColor := "ffee00"     ; held/pressed key fill
k_MouseBackColor := "E6E6E6"     ; normal mouse button/wheel fill
k_MouseActiveColor := "FFD966"   ; mouse button hold / wheel flash fill
k_KeyTextColor := "000000"       ; key label text

; Global show/hide toggle. The keyboard is a passive display that runs while you
; type, so a bare key would clash with normal typing -- use a modifier combo.
; Change k_ToggleHotkey if Ctrl+Alt+K collides with something (keep
; k_ToggleHotkeyLabel in sync; it's only the text shown in the tray menu).
k_ToggleHotkey := "^!k"              ; ^ = Ctrl, ! = Alt  -> Ctrl+Alt+K
k_ToggleHotkeyLabel := "Ctrl+Alt+K"

k_MenuItemHide := "Hide on-screen &keyboard`t" . k_ToggleHotkeyLabel
k_MenuItemShow := "Show on-screen &keyboard`t" . k_ToggleHotkeyLabel

k_Monitor := ""  ; Leave empty for primary monitor, or specify 2, 3, etc.

; Transparency: Alt+Up / Alt+Down and Alt+WheelUp / Alt+WheelDown adjust the
; keyboard's overall opacity, but only while the keyboard window is focused.
; Up / WheelUp = more opaque; Down / WheelDown = more see-through. Flip the sign
; of k_TransparencyStep at registration if you prefer the opposite direction.
k_Transparency := 255       ; current alpha: 255 = fully opaque, lower = more transparent
k_TransparencyStep := 15    ; amount each keypress / wheel notch changes the alpha
k_TransparencyMin := 30     ; floor so the window never fades away completely

;---- Calculate dimensions based on font size
k_KeyWidth := k_FontSize * 3
k_KeyHeight := k_FontSize * 3
k_KeyMargin := Floor(k_FontSize / 6)
k_SpacebarWidth := k_FontSize * 25
k_KeyWidthHalf := Floor(k_KeyWidth / 2)
k_ModifierWidth := k_KeyWidth + 20  ; Extra width for modifier keys
k_ShiftWidth := k_KeyWidth + 40     ; Wider for Shift
k_Row3Offset := k_KeyWidthHalf + 18 ; Offset for third row (ASDF...)

; F-row keys: same WIDTH as normal keys, but SHORTER, with a smaller font so the
; longer labels (Esc, F10, F11, F12, Del) still fit. Lower k_FKeyHeight toward
; Floor(k_KeyHeight / 2) if you want the row even shorter.
k_FKeyFontSize := k_FontSize - 2          ; smaller font just for the F-row
k_FKeyHeight := Floor(k_KeyHeight * 0.6)  ; ~60% of normal key height

;---- Create the GUI
MyGui := Gui()
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

;---- Block F10 / lone-Alt from opening the window's (nonexistent) menu, which
; otherwise traps the GUI in menu-modal mode: the F10 highlight sticks, other
; F-keys stop registering, and stray keys beep. Only matters when the GUI is
; focused (never during normal use), but the fix is cheap and clean.
OnMessage(0x0112, WM_SYSCOMMAND)  ; WM_SYSCOMMAND

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

;---- Register all ASCII character hotkeys (45 to 93: - through ])
Loop 49 {
    k_ASCII := 44 + A_Index
    k_char := Chr(k_ASCII)
    k_char := StrUpper(k_char)
    ; Skip special characters that cause issues
    if !InStr("<>^~,", k_char) {
        Hotkey("~*" . k_char, KeyPress)
    }
}

;---- Register modifier key hotkeys
for key in ["LShift", "RShift", "LCtrl", "RCtrl", "LAlt", "RAlt", "LWin", "RWin"]
    Hotkey("~*" . key, ModifierPress)

;---- Register special key hotkeys
for key in ["Backspace", "Space", "Tab", "Enter", ",", "'"]
    Hotkey("~*" . key, KeyPress)


;---- Register arrow key hotkeys
for key in ["Up", "Left", "Down", "Right"]
    Hotkey("~*" . key, KeyPress)

;---- Register F-row hotkeys (F1-F12 and Del light up like normal keys)
for key in ["F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12", "Delete"]
    Hotkey("~*" . key, KeyPress)

;---- Register mouse hotkeys
for key in ["LButton", "RButton"]
    Hotkey("~*" . key, MouseButtonPress)
for key in ["WheelUp", "WheelDown"]
    Hotkey("~*" . key, MouseWheelPress)

;---- Register Esc key: lights up the on-screen Esc AND hides GUI when active.
; Passthrough (~*) so Esc still reaches other apps. ^Esc::ExitApp stays in effect
; because that more-specific variant wins for Ctrl+Esc.
Hotkey("~*Esc", EscPress)

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

;---- Tray menu setup
TrayMenu := A_TrayMenu
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
    global buttons, buttonNormalColors, k_KeyActiveColor, k_MouseActiveColor

    if !buttons.Has(buttonKey)
        return

    ctrl := buttons[buttonKey]

    ; Use the key's stored normal color when turning it off.
    ; This matters because mouse buttons can use a different normal color than keys.
    if isActive
        color := isMouse ? k_MouseActiveColor : k_KeyActiveColor
    else
        color := buttonNormalColors.Has(buttonKey) ? buttonNormalColors[buttonKey] : "E6E6E6"

    ; Text controls sometimes need a forced repaint after their background is changed,
    ; especially on themed Windows controls.
    ctrl.Opt("Background" . color)
    try ctrl.Redraw()
    try DllCall("RedrawWindow", "Ptr", ctrl.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x0105)
}

;---- Hotkey handler for regular keys
KeyPress(ThisHotkey) {
    global k_ID, buttons
    
    ; Get the key from A_ThisHotkey and remove the hotkey prefix (~*)
    thisKey := A_ThisHotkey
    thisKey := StrReplace(thisKey, "~", "")
    thisKey := StrReplace(thisKey, "*", "")
    
    ; Map key names to button labels
    if thisKey = "Backspace"
        buttonLabel := "BS"
    else if thisKey = "Enter"
        buttonLabel := "Enter"
    else if thisKey = "Tab"
        buttonLabel := "Tab"
    else if thisKey = "Space"
        buttonLabel := "Space"
    else if thisKey = "Up"
        buttonLabel := "↑"
    else if thisKey = "Left"
        buttonLabel := "←"
    else if thisKey = "Down"
        buttonLabel := "↓"
    else if thisKey = "Right"
        buttonLabel := "→"
    else
        buttonLabel := thisKey
    
    if buttons.Has(thisKey) {
        SetKeyActive(thisKey, true)
        KeyWait(thisKey)
        SetKeyActive(thisKey, false)
    }
}

;---- Hotkey handler for modifier keys (Shift, Ctrl, Alt, Win)
ModifierPress(ThisHotkey) {
    global k_ID, buttons
    
    ; Extract key name: LShift, RShift, LCtrl, RCtrl, LAlt, RAlt, LWin, RWin
    thisKey := A_ThisHotkey
    thisKey := StrReplace(thisKey, "~*", "")
    
    ; Map to button labels and store original text
    if InStr(thisKey, "Shift") {
        buttonLabel := "Shift"
        originalText := "Shift"
    } else if InStr(thisKey, "Ctrl") {
        buttonLabel := "Ctrl"
        originalText := "Ctrl"
    } else if InStr(thisKey, "Alt") {
        buttonLabel := "Alt"
        originalText := "Alt"
    } else if InStr(thisKey, "Win") {
        buttonLabel := "Win"
        originalText := "Win"
    } else {
        buttonLabel := thisKey
        originalText := thisKey
    }
    
    if buttons.Has(buttonLabel)
        SetKeyActive(buttonLabel, true)

    KeyWait(thisKey)

    if buttons.Has(buttonLabel)
        SetKeyActive(buttonLabel, false)
}


;---- Hotkey handler for mouse buttons, including click-and-hold visual feedback
MouseButtonPress(ThisHotkey) {
    global buttons

    thisKey := A_ThisHotkey
    thisKey := StrReplace(thisKey, "~*", "")

    if buttons.Has(thisKey) {
        SetKeyActive(thisKey, true, true)
        KeyWait(thisKey)
        SetKeyActive(thisKey, false, true)
    }
}

;---- Hotkey handler for mouse wheel events
MouseWheelPress(ThisHotkey) {
    global buttons

    thisKey := A_ThisHotkey
    thisKey := StrReplace(thisKey, "~*", "")

    if buttons.Has(thisKey) {
        SetKeyActive(thisKey, true, true)
        SetTimer(() => SetKeyActive(thisKey, false, true), -150)
    }
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

;---- Handle drag-to-move for borderless window
WM_LBUTTONDOWN(wParam, lParam, msg, hwnd) {
    global MyGui
    PostMessage(0x00A1, 2)  ; 0x00A1 = WM_NCLBUTTONDOWN, 2 = HTCAPTION
}

;---- Swallow menu activation (F10 / lone Alt) so the borderless GUI can't get
; stuck in menu-modal mode. Returning 0 (not "") suppresses default handling.
WM_SYSCOMMAND(wParam, lParam, msg, hwnd) {
    global MyGui
    if (hwnd = MyGui.Hwnd && (wParam & 0xFFF0) = 0xF100)  ; SC_KEYMENU
        return 0
}

;---- Esc handler: light up the Esc key, and hide the GUI if it's the active window
EscPress(ThisHotkey) {
    global buttons, MyGui, k_IsVisible

    ; Light up the on-screen Esc like any other key.
    if buttons.Has("Escape") {
        SetKeyActive("Escape", true)
        KeyWait("Escape")
        SetKeyActive("Escape", false)
    }

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
