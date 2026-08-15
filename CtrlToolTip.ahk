/*
Adds a standard Windows tooltip to a Gui control.
Base version 1.1 by Mesut Akcan, 2026-07-08
GitHub repository: https://github.com/mesutakcan/CtrlToolTip

MODIFIED: adds control over how long the tooltip stays on screen, with an
optional auto-scale so that longer tip text gets more reading time.

Usage:
	CtrlToolTip(ctrl, "Short tip")          ; duration auto-scales with text length
	CtrlToolTip(ctrl, "Long tip...", 20000) ; force 20 seconds for this one control
	CtrlToolTip.AutoDuration := false       ; revert to Windows' default timing

Tunables (set before the first CtrlToolTip() call, or any time):
	CtrlToolTip.BaseMs      minimum display time
	CtrlToolTip.MsPerChar   ms added per character of tip text
	CtrlToolTip.MaxMs       ceiling for the auto-scaled value
	CtrlToolTip.InitialMs   hover delay before the tip appears ("" = OS default)
	CtrlToolTip.MaxWidth    px before the text wraps to another line

Note: Windows stores the delay in the low WORD of lParam, so 65535 ms is a hard
ceiling. Anything above that wraps around; keep MaxMs well under it.
*/

#Requires AutoHotkey v2.0

class CtrlToolTip {

	; ---------------------------------------------------------------- tunables
	static AutoDuration := true            ; scale display time to text length
	static BaseMs       := 4000            ; floor, in ms
	static MsPerChar    := 55              ; ms added per character
	static MaxMs        := 30000           ; ceiling for auto-scaled values
	static InitialMs    := ""              ; "" = leave OS hover delay alone
	static MaxWidth     := A_ScreenWidth   ; wrap width in px

	; -------------------------------------------------------- internal state
	static tipHandles        := Map() ; parent Gui HWND  -> tooltip control HWND
	static textBuffers       := Map() ; control HWND     -> text Buffer (anti-GC)
	static registeredControls := Map() ; control HWND    -> true
	static durations         := Map() ; control HWND     -> display time in ms
	static defaultAutoPop    := 5000  ; Windows' own auto-pop time
	static hooked            := false ; WM_NOTIFY monitor installed?

	; ctrl:     Target Gui.Control that should display the tooltip.
	; text:     Tooltip text to show when the mouse hovers the control.
	; duration: Optional display time in ms. Omit to auto-scale from text length
	;           (or to use the Windows default when AutoDuration is false).
	static Call(ctrl, text, duration := "") {
		static GWL_STYLE := -16   ; offset for GetWindowLongPtr
		static SS_NOTIFY := 0x0100 ; static controls need this to get tooltips
		hTip := 0

		; Ensure the provided control is a Gui.Control object
		if !(ctrl is Gui.Control)
			throw TypeError("CtrlToolTip: Gui.Control expected.", -1)

		guiHwnd := ctrl.Gui.Hwnd ; parent Gui HWND, used to group tooltips

		; Ensure static text controls have the SS_NOTIFY style for tooltip support.
		if (ctrl.Type = "Text") {
			gwlFunc := (A_PtrSize = 8) ? "GetWindowLongPtr" : "GetWindowLong"
			swlFunc := (A_PtrSize = 8) ? "SetWindowLongPtr" : "SetWindowLong"
			style := DllCall(gwlFunc, "Ptr", ctrl.Hwnd, "Int", GWL_STYLE, "Ptr")
			if !(style & SS_NOTIFY)
				DllCall(swlFunc, "Ptr", ctrl.Hwnd, "Int", GWL_STYLE, "Ptr", style | SS_NOTIFY, "Ptr")
		}

		; Check if a tooltip control already exists for this Gui.
		if this.tipHandles.Has(guiHwnd)
			hTip := this.tipHandles[guiHwnd]

		; Get or create the tooltip window handle for this Gui.
		if !hTip || !DllCall("IsWindow", "Ptr", hTip, "Int") {
			hTip := DllCall(
				  "CreateWindowEx"
				, "UInt", 0                 ; dwExStyle
				, "Str", "tooltips_class32" ; lpClassName
				, "Ptr", 0                  ; lpWindowName
				, "UInt", 0x80000003        ; tooltip window styles
				, "Int", 0x80000000         ; CW_USEDEFAULT
				, "Int", 0x80000000
				, "Int", 0x80000000
				, "Int", 0x80000000
				, "Ptr", guiHwnd            ; hwndParent
				, "Ptr", 0                  ; hMenu
				, "Ptr", 0                  ; hInstance
				, "Ptr", 0                  ; lpParam
				, "Ptr"                     ; returns the tooltip control's HWND
			)

			if !hTip
				throw Error("CtrlToolTip: Failed to create tooltip control.", -1)

			; Max tooltip width, so the text can wrap to multiple lines.
			SendMessage(0x0418, 0, this.MaxWidth, hTip) ; TTM_SETMAXTIPWIDTH

			; Remember the OS auto-pop time so tips can be put back to it.
			osPop := SendMessage(0x0415, 2, 0, hTip)    ; TTM_GETDELAYTIME, TTDT_AUTOPOP
			this.defaultAutoPop := (osPop > 0) ? osPop : 5000

			; Optional custom hover delay before the tip appears.
			if (this.InitialMs != "")
				SendMessage(0x0403, 3, this.InitialMs, hTip) ; TTM_SETDELAYTIME, TTDT_INITIAL

			this.tipHandles[guiHwnd] := hTip
		}

		; Prepare the buffer for the tooltip text.
		ti := Buffer(24 + (A_PtrSize * 6), 0)
		textBuf := Buffer(StrPut(text, "UTF-16") * 2, 0)
		StrPut(text, textBuf, "UTF-16")

		NumPut("UInt", ti.Size, ti)                          ; cbSize
		NumPut("UInt", 0x11, ti, 4)                          ; TTF_IDISHWND | TTF_SUBCLASS
		NumPut("Ptr", guiHwnd, ti, 8)                        ; hwnd
		NumPut("Ptr", ctrl.Hwnd, ti, 8 + A_PtrSize)          ; uId
		NumPut("Ptr", textBuf.Ptr, ti, 24 + (A_PtrSize * 3)) ; lpszText

		; Update the tip text, or add the tool if this control is new.
		if this.registeredControls.Has(ctrl.Hwnd)
			SendMessage(0x0439, 0, ti.Ptr, hTip) ; TTM_UPDATETIPTEXTW
		else {
			SendMessage(0x0432, 0, ti.Ptr, hTip) ; TTM_ADDTOOLW
			this.registeredControls[ctrl.Hwnd] := true
		}

		; Keep the buffer alive; otherwise the tip shows empty text.
		this.textBuffers[ctrl.Hwnd] := textBuf

		; ---- duration ----
		; The delay time belongs to the tooltip *control*, not to an individual
		; tool, so it has to be applied per control right before each tip shows
		; (see OnNotify). Store this control's value now.
		if (duration = "")
			duration := this.AutoDuration ? this.CalcDuration(text) : this.defaultAutoPop
		this.durations[ctrl.Hwnd] := Min(Max(Integer(duration), 100), 65535)

		; Install the TTN_SHOW watcher once.
		if !this.hooked {
			OnMessage(0x004E, ObjBindMethod(this, "OnNotify")) ; WM_NOTIFY
			this.hooked := true
		}
	}

	; Display time for a given string. Tweak the tunables above to taste.
	static CalcDuration(text) {
		return Min(this.BaseMs + StrLen(text) * this.MsPerChar, this.MaxMs)
	}

	; Fires just before a tooltip is displayed. Sets the auto-pop time for the
	; control that is about to show, so each control can have its own duration.
	static OnNotify(wParam, lParam, msg, hwnd) {
		static TTN_SHOW := -521, TTM_SETDELAYTIME := 0x0403, TTDT_AUTOPOP := 2

		; Only care about Guis we've attached tooltips to.
		if !this.tipHandles.Has(hwnd)
			return
		; NMHDR: hwndFrom (Ptr), idFrom (UPtr), code (Int)
		if (NumGet(lParam, A_PtrSize * 2, "Int") != TTN_SHOW)
			return

		hFrom  := NumGet(lParam, 0, "Ptr")          ; the tooltip control
		idFrom := NumGet(lParam, A_PtrSize, "UPtr") ; = hovered control's HWND

		if this.durations.Has(idFrom)
			DllCall("user32\SendMessageW", "Ptr", hFrom, "UInt", TTM_SETDELAYTIME
				, "Ptr", TTDT_AUTOPOP, "Ptr", this.durations[idFrom])

		; Return nothing, so AHK's normal WM_NOTIFY processing continues.
		; (ListViews and other common controls depend on it.)
	}
}
