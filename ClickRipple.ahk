; ==============================================================================
; ClickRipple.ahk  --  Version date: 8-13-2026
; Mouse-click ripple engine for InputEcho.ahk.  kunkel321 + Claude
;
; Not standalone -- included by InputEcho.ahk, which owns the Cfg map, the
; INI, the tray menu, and the mouse hotkeys. This file is only the renderer plus
; its state machine. Tuned in ClickRippleDemo.ahk.
;
; TWO ENCODINGS, ON PERPENDICULAR AXES
;
; 1. WHICH INPUT -- by the position of the thick arc on the ring.
;    Buttons own the HORIZONTAL axis: thick-left = LButton, thick-right = RButton.
;    The wheel owns the VERTICAL axis: thick-top = wheel up, thick-bottom = wheel
;    down, both = MButton. Positionally iconic -- the ring looks like the mouse
;    under the viewer's hand -- so nothing has to be learned, and because the two
;    axes are perpendicular they cannot collide with each other.
;
; 2. PRESS OR RELEASE -- by the DIRECTION the ring travels.
;    Down contracts (big -> small): converges on the target, reads as committing.
;    Up expands (small -> big): blooms outward, reads as releasing.
;    A normal click is therefore one continuous heartbeat: shrink in, bounce out.
;    Opposite directions cannot smear together the way two identical ripples would.
;
;    The heartbeat is ONE ripple. On release the in-phase ripple is handed off in
;    place -- same slot, same center, continuing from its current radius and alpha.
;    Two independent overlapping ripples would cross mid-flight and read as noise.
;
;    Wheel events have no press/release pair, so they are out-phase only.
;
; 3. MINIMUM HEARTBEAT -- the shape always completes.
;    A real click is 30-80ms against a ~300ms contract, so reversing at whatever
;    radius the ring happened to reach would be an imperceptible wobble at exactly
;    the speed people actually click. Instead a release mid-contraction SNAPS the
;    rest of the way in over SnapMs (scaled by the distance left), then chains into
;    the bloom. This decouples the animation from the physical event timing, which
;    is fine: the ripple is a notification, not a telemetry readout, and nobody
;    watching a screencast can see the mouse-up anyway. A genuine HOLD still looks
;    different, because contraction, park and bloom stay visibly separate beats.
;
; 4. ONE LIVE HEARTBEAT PER BUTTON.
;    Pressing a button retires whatever that button was still animating, so a
;    double-click renders as pulse-cut-pulse. No detection, no threshold, no fourth
;    signature to learn.
;
; 5. WHILE HELD, THE RING FOLLOWS THE CURSOR.
;    A ring pinned to where the press started is wrong the instant you drag away.
;    Tracking is nearly free: the geometry doesn't change while parked, so a drag
;    only re-blits the existing bitmap and never re-renders.
;
; RENDERING
; Each ripple is a small click-through layered window drawn with GDI+ and blitted
; via UpdateLayeredWindow. Windows are POOLED (created once, reused round-robin) --
; creating one per click flickers and drops frames. They are sized to the ripple,
; not the screen, so each blit is tiny and doesn't compete with the screen recorder.
;
; The three extended styles are all load-bearing:
;   WS_EX_LAYERED     0x00080000  required by UpdateLayeredWindow
;   WS_EX_TRANSPARENT 0x00000020  click-through, or the ring eats your next click
;   WS_EX_NOACTIVATE  0x08000000  never steals focus mid-demo (the fatal one)
;
; Z-ORDER is NOT handled here. The main script owns one ordered raise pass so the
; keyboard and the ripples can't race each other -- see RaiseAll() over there.
; ==============================================================================

global RIP_POOL_SIZE := 6
global RIP_HOLD_MAX_MS := 8000   ; safety valve: if a button-up is never seen (focus
                                 ; loss, hung app, RDP drop) a parked ring would
                                 ; otherwise sit on screen forever
global RIP_IN_TAIL := 0.25       ; fraction of a non-parked in-phase spent fading out
global RIP_OUT_RISE := 0.15      ; fraction of the out-phase spent ramping alpha up
                                 ; from the handoff value, so the pulse can't flicker

global RipToken := 0, RipPenThin := 0, RipPenThick := 0
global RipPool := [], RipBufSize := 0
global RipDpi := A_ScreenDPI / 96   ; geometry is PHYSICAL px; scale so it looks the
                                    ; same size at 100% and 125%
global RipBtn := Map("L", 0, "R", 0, "M", 0)   ; the ONE ripple each button owns,
                                               ; through both phases (see rule 4)

; ==============================================================================
;  Setup / teardown
; ==============================================================================

RippleInit() {
    global RipToken, RipPenThin, RipPenThick, RipPool, RIP_POOL_SIZE
    DllCall("LoadLibrary", "Str", "gdiplus")
    si := Buffer(24, 0)
    NumPut("UInt", 1, si, 0)
    DllCall("gdiplus\GdiplusStartup", "Ptr*", &RipToken, "Ptr", si, "Ptr", 0)

    ; Two pens, created ONCE. Per frame we only reset color and width -- building
    ; and destroying pens 45 times a second would be pointless garbage.
    DllCall("gdiplus\GdipCreatePen1", "UInt", 0xFF000000, "Float", 1, "Int", 2, "Ptr*", &RipPenThin)
    DllCall("gdiplus\GdipCreatePen1", "UInt", 0xFF000000, "Float", 1, "Int", 2, "Ptr*", &RipPenThick)
    RippleApplyCaps()

    Loop RIP_POOL_SIZE {
        ; -DPIScale: we size and position this window ourselves in physical pixels,
        ; so AHK's automatic scaling would double-apply.
        g := Gui("-Caption +ToolWindow +AlwaysOnTop -DPIScale +E0x08080020")
        RipPool.Push({ gui: g, hwnd: g.Hwnd, hdc: 0, hbm: 0, obm: 0, pBits: 0,
                       pG: 0, pBmp: 0, active: false, kind: "L", phase: "out",
                       cx: 0, cy: 0, t0: 0, dur: 1, r0: 0, r1: 0, a0: 255,
                       curR: 0, curA: 0, bx: 0, by: 0,
                       chain: false, follow: false, holding: false, blitted: false })
    }
    RippleEnsureBuffers()
}

; LineCapFlat = 0, LineCapRound = 2. Round caps taper the thick arc's ends so it
; blends into the thin ring instead of butting against it with a square notch.
RippleApplyCaps() {
    global RipPenThick, Cfg
    cap := Cfg["RoundCaps"] ? 2 : 0
    DllCall("gdiplus\GdipSetPenStartCap", "Ptr", RipPenThick, "Int", cap)
    DllCall("gdiplus\GdipSetPenEndCap",   "Ptr", RipPenThick, "Int", cap)
}

; The DIB is allocated once and reused every frame; it only needs rebuilding when a
; setting changes the maximum extent a ripple can reach. Sizes round UP to a 32px
; step so dragging a radius slider doesn't reallocate six surfaces per pixel.
RippleEnsureBuffers() {
    global RipPool, RipBufSize, Cfg, RipDpi
    maxR   := Cfg["EndR"] * RipDpi
    maxPen := Cfg["ThinPen"] * RipDpi * Cfg["ThickRatio"]
    need   := Ceil((2 * (maxR + maxPen) + 12) / 32) * 32
    if (need = RipBufSize)
        return
    RipBufSize := need
    for rp in RipPool {
        RippleHide(rp)
        RippleFreeSurface(rp)
        RippleMakeSurface(rp, RipBufSize)
    }
}

RippleMakeSurface(rp, size) {
    rp.hdc := DllCall("CreateCompatibleDC", "Ptr", 0, "Ptr")

    bi := Buffer(40, 0)
    NumPut("UInt", 40, bi, 0)          ; biSize
    NumPut("Int", size, bi, 4)         ; biWidth
    NumPut("Int", -size, bi, 8)        ; biHeight NEGATIVE = top-down rows
    NumPut("UShort", 1, bi, 12)        ; biPlanes
    NumPut("UShort", 32, bi, 14)       ; biBitCount -- we need the alpha channel
    NumPut("UInt", 0, bi, 16)          ; biCompression = BI_RGB

    rp.hbm := DllCall("CreateDIBSection", "Ptr", rp.hdc, "Ptr", bi, "UInt", 0,
                      "Ptr*", &pBits := 0, "Ptr", 0, "UInt", 0, "Ptr")
    rp.pBits := pBits
    rp.obm := DllCall("SelectObject", "Ptr", rp.hdc, "Ptr", rp.hbm, "Ptr")

    ; Bind GDI+ to the DIB's pixels as PixelFormat32bppPARGB (0xE200B) rather than
    ; pulling a Graphics off the HDC. UpdateLayeredWindow with AC_SRC_ALPHA expects
    ; PREMULTIPLIED pixels; a Graphics from an HDC doesn't guarantee it writes them.
    ; Harmless while every pen is fully opaque (the two forms are identical at alpha
    ; 255) but it produces bright halos on antialiased edges the moment a pen goes
    ; semi-transparent -- which the opacity settings do. Naming the format makes
    ; GDI+ blend in premultiplied space and the blit is simply correct.
    ; The DIB is top-down, so pBits is the FIRST row and the stride is positive.
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", size, "Int", size,
            "Int", size * 4, "Int", 0xE200B, "Ptr", rp.pBits, "Ptr*", &pBmp := 0)
    rp.pBmp := pBmp
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", rp.pBmp, "Ptr*", &pG := 0)
    rp.pG := pG
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", rp.pG, "Int", 4)   ; AntiAlias
}

RippleFreeSurface(rp) {
    if rp.pG
        DllCall("gdiplus\GdipDeleteGraphics", "Ptr", rp.pG), rp.pG := 0
    if rp.pBmp
        DllCall("gdiplus\GdipDisposeImage", "Ptr", rp.pBmp), rp.pBmp := 0
    if rp.hdc {
        if rp.obm
            DllCall("SelectObject", "Ptr", rp.hdc, "Ptr", rp.obm)
        if rp.hbm
            DllCall("DeleteObject", "Ptr", rp.hbm)
        DllCall("DeleteDC", "Ptr", rp.hdc)
        rp.hdc := 0, rp.hbm := 0, rp.obm := 0
    }
}

RippleShutdown(*) {
    global RipPool, RipToken, RipPenThin, RipPenThick
    for rp in RipPool
        RippleFreeSurface(rp)
    if RipPenThin
        DllCall("gdiplus\GdipDeletePen", "Ptr", RipPenThin)
    if RipPenThick
        DllCall("gdiplus\GdipDeletePen", "Ptr", RipPenThick)
    if RipToken
        DllCall("gdiplus\GdiplusShutdown", "Ptr", RipToken)
}

; ==============================================================================
;  Public entry points -- called from the main script's mouse handlers
; ==============================================================================

; kind: "L" | "R" | "M"
RippleDown(kind) {
    global Cfg, RipBtn
    if !Cfg["ShowMouse"]
        return
    MouseGetPos(&mx, &my, &win)
    if RippleSkipWindow(win)
        return

    ; SUPERSEDE (rule 4): this button is being pressed again while its previous
    ; heartbeat still plays, so that heartbeat is stale. Retire it.
    old := RipBtn[kind]
    if (old && old.active)
        RippleHide(old)

    rp := RippleSlot()
    rp.cx := mx, rp.cy := my
    RippleStart(rp, kind, "in", Cfg["EndR"], Cfg["StartR"], Cfg["DurationIn"], 255)
    rp.follow := true                  ; track the cursor for as long as it's held
    RipBtn[kind] := rp
    RippleShow(rp)
}

RippleUp(kind) {
    global Cfg, RipBtn
    if !Cfg["ShowMouse"]
        return
    rp := RipBtn[kind]

    if (rp && rp.active && rp.phase = "in") {
        rp.follow := false             ; released: the bloom stays where it happened
        if rp.holding {
            RippleStart(rp, kind, "out", Cfg["StartR"], Cfg["EndR"], Cfg["Duration"], 255)
        } else {
            ; MINIMUM HEARTBEAT (rule 3): finish contracting fast, then chain out.
            span := Max(1, Cfg["EndR"] - Cfg["StartR"])
            left := Min(1, Max(0, (rp.curR - Cfg["StartR"]) / span))
            RippleStart(rp, kind, "in", rp.curR, Cfg["StartR"],
                        Max(20, Cfg["SnapMs"] * left), 255)
            rp.chain := true
        }
        SetTimer(RippleTick, Cfg["FrameMs"])
        return
    }

    ; The press ripple already expired -- a hold longer than the contract with
    ; parking switched off. Bloom a fresh one at the release point.
    MouseGetPos(&mx, &my, &win)
    if RippleSkipWindow(win)
        return
    r2 := RippleSlot()
    r2.cx := mx, r2.cy := my
    RippleStart(r2, kind, "out", Cfg["StartR"], Cfg["EndR"], Cfg["Duration"], 255)
    RipBtn[kind] := r2
    RippleShow(r2)
}

; dir: "WU" | "WD"
RippleWheel(dir) {
    global Cfg
    if !Cfg["ShowMouse"]
        return
    MouseGetPos(&mx, &my, &win)
    if RippleSkipWindow(win)
        return
    rp := RippleSlot()
    rp.cx := mx, rp.cy := my
    RippleStart(rp, dir, "out", Cfg["StartR"], Cfg["EndR"], Cfg["Duration"], 255)
    RippleShow(rp)
}

; True while anything is animating -- lets the main script pick a fast or lazy
; cadence for its Z-order pass.
RippleBusy() {
    global RipPool
    for rp in RipPool
        if rp.active
            return true
    return false
}

; ==============================================================================
;  Internals
; ==============================================================================

; Arms a ripple for one phase. r0/r1 are LOGICAL px (DPI scaling happens at draw
; time). a0 is the alpha to start at, which is how a handoff stays continuous. The
; duration is passed rather than read from Cfg because the snap-in phase runs on a
; computed duration, not a configured one.
RippleStart(rp, kind, phase, r0, r1, dur, a0) {
    rp.kind    := kind
    rp.phase   := phase
    rp.r0      := r0
    rp.r1      := r1
    rp.dur     := Max(1, dur)
    rp.a0      := a0
    rp.t0      := A_TickCount
    rp.active  := true
    rp.holding := false
    rp.blitted := false
    rp.chain   := false
    rp.follow  := false   ; a recycled slot must not inherit cursor-tracking;
                          ; RippleDown re-arms it explicitly
}

RippleShow(rp) {
    global Cfg
    RippleRender(rp)                                   ; paint BEFORE showing, no flash
    DllCall("ShowWindow", "Ptr", rp.hwnd, "Int", 4)    ; SW_SHOWNOACTIVATE
    RaiseAll(true)                                     ; main owns ordering; force past
                                                       ; the throttle so a new ring is
                                                       ; never briefly underneath
    SetTimer(RippleTick, Cfg["FrameMs"])
}

RippleHide(rp) {
    rp.active  := false
    rp.holding := false
    rp.follow  := false
    DllCall("ShowWindow", "Ptr", rp.hwnd, "Int", 0)    ; SW_HIDE
}

RippleSlot() {
    global RipPool
    oldest := RipPool[1]
    for rp in RipPool {
        if !rp.active
            return rp
        if (rp.t0 < oldest.t0)
            oldest := rp
    }
    return oldest   ; pool exhausted -- recycle the one closest to finishing
}

; One shared timer walks every live ripple, then re-asserts Z-order once for the
; whole stack. Stops itself when nothing is animating, so idle costs nothing.
RippleTick() {
    global RipPool
    any := false
    for rp in RipPool {
        if !rp.active
            continue
        RippleRender(rp)
        if rp.active
            any := true
    }
    if any
        RaiseAll()
    else
        SetTimer(RippleTick, 0)
}

RippleRender(rp) {
    global Cfg, RipDpi, RipBufSize, RipPenThin, RipPenThick
    global RIP_HOLD_MAX_MS, RIP_IN_TAIL, RIP_OUT_RISE

    ; While the owning button is down the ring tracks the cursor (rule 5).
    if rp.follow {
        MouseGetPos(&fx, &fy)
        rp.cx := fx, rp.cy := fy
    }

    isIn    := (rp.phase = "in")
    elapsed := A_TickCount - rp.t0
    t       := elapsed / rp.dur

    if (t >= 1) {
        if isIn {
            ; A snap-in armed by a release chains straight into the bloom -- this is
            ; what guarantees the full heartbeat.
            if rp.chain {
                RippleStart(rp, rp.kind, "out", Cfg["StartR"], Cfg["EndR"], Cfg["Duration"], 255)
                RippleRender(rp)
                return
            }
            ; Otherwise the button is still down: park at the cursor waiting for the
            ; release, or fade if parking is switched off.
            if (Cfg["HoldRing"] && elapsed < RIP_HOLD_MAX_MS) {
                t := 1
                rp.holding := true
            } else {
                RippleHide(rp)
                return
            }
        } else {
            RippleHide(rp)
            return
        }
    }

    ; A parked ring's GEOMETRY never changes -- only its position, as you drag. So
    ; re-blit the bitmap we already have and skip the entire GDI+ redraw. Without
    ; this, holding a button would burn 45 identical re-renders a second.
    if (rp.holding && rp.blitted) {
        if (rp.cx != rp.bx || rp.cy != rp.by)
            RippleBlit(rp, rp.curA)
        return
    }

    rLog := rp.r0 + (rp.r1 - rp.r0) * RippleEase(t)
    r    := rLog * RipDpi

    ; Stroke weight keys off how LARGE the ring currently is, not off elapsed time,
    ; so it's direction-agnostic: small rings are always heavy, large rings always
    ; fine, contracting or expanding. Keying it to time would make an in-phase
    ; thinnest at its most emphatic moment.
    span  := Max(1, Cfg["EndR"] - Cfg["StartR"])
    frac  := Min(1, Max(0, (rLog - Cfg["StartR"]) / span))
    thin  := Max(1, Cfg["ThinPen"] * RipDpi * (1 - 0.55 * frac))
    thick := thin * Cfg["ThickRatio"]

    if isIn {
        ; Full brightness while converging. The tail only exists so a non-parked
        ; in-phase has something to fade into instead of popping off screen.
        alpha := (!Cfg["HoldRing"] && t > (1 - RIP_IN_TAIL))
                 ? Round(255 * (1 - (t - (1 - RIP_IN_TAIL)) / RIP_IN_TAIL))
                 : 255
    } else {
        ; Ramp up from the handoff alpha, then fade out. At t=0 this evaluates to
        ; exactly a0, which is what makes the reversal seamless.
        rise  := Min(1, t / RIP_OUT_RISE)
        alpha := Round((rp.a0 + (255 - rp.a0) * rise) * (1 - t) ** Cfg["AlphaPow"])
    }
    alpha := Max(1, Min(255, alpha))

    rp.curR := rLog     ; remembered for a possible handoff on button-up
    rp.curA := alpha

    ; Per-element opacity lives in the PEN alpha; the animation's fade stays on the
    ; window's SourceConstantAlpha. They multiply, so the settings choose each
    ; stroke's peak weight and the fade then carries both down together.
    rgb   := RippleColor(rp.kind)
    ringA := Round(255 * Cfg["RingOpacity"] / 100)
    arcA  := Round(255 * Cfg["ArcOpacity"] / 100)

    DllCall("gdiplus\GdipGraphicsClear", "Ptr", rp.pG, "UInt", 0x00000000)
    DllCall("gdiplus\GdipSetPenColor", "Ptr", RipPenThin,  "UInt", (ringA << 24) | rgb)
    DllCall("gdiplus\GdipSetPenWidth", "Ptr", RipPenThin,  "Float", thin)
    DllCall("gdiplus\GdipSetPenColor", "Ptr", RipPenThick, "UInt", (arcA << 24) | rgb)
    DllCall("gdiplus\GdipSetPenWidth", "Ptr", RipPenThick, "Float", thick)

    c := RipBufSize / 2
    x := c - r, y := c - r, d := r * 2

    DllCall("gdiplus\GdipDrawEllipse", "Ptr", rp.pG, "Ptr", RipPenThin,
            "Float", x, "Float", y, "Float", d, "Float", d)

    sweep := (rp.kind = "L" || rp.kind = "R") ? Cfg["ArcSweep"] : Cfg["WheelSweep"]
    for ctr in RippleArcCenters(rp.kind) {
        DllCall("gdiplus\GdipDrawArc", "Ptr", rp.pG, "Ptr", RipPenThick,
                "Float", x, "Float", y, "Float", d, "Float", d,
                "Float", ctr - sweep / 2, "Float", sweep)
    }

    RippleBlit(rp, alpha)
    rp.blitted := true
}

; GDI+ angles: 0 deg = 3 o'clock, increasing CLOCKWISE. So 180 = left, 270 = top,
; 90 = bottom.
;
; Buttons own the HORIZONTAL axis and the wheel owns the VERTICAL one. An earlier
; version rotated the wheel arc off top by an adjustable offset, which meant a big
; enough offset slid it straight into the left- or right-button position and the
; two became indistinguishable. Pinning the wheel to top/bottom makes that
; collision impossible by construction rather than merely unlikely -- and the
; vertical axis is the scroll axis anyway, so the cue is iconic not arbitrary.
;
; Middle click draws BOTH arcs. Symmetric reads as "no direction", so it can't be
; mistaken for either scroll direction while staying in the same visual family.
RippleArcCenters(kind) {
    switch kind {
        case "L":  return [180]        ; thick on the left    = left button
        case "R":  return [0]          ; thick on the right   = right button
        case "WU": return [270]        ; thick on top         = wheel up
        case "WD": return [90]         ; thick on bottom      = wheel down
        case "M":  return [270, 90]    ; thick top AND bottom = middle button
    }
    return [0]
}

; Color1 and Color2 are shared with the on-screen keyboard's mouse block, so the
; ring and the L/R buttons over there always agree.
RippleColor(kind) {
    global Cfg
    return (kind = "R" && Cfg["TwoColors"]) ? Cfg["Color2"] : Cfg["Color1"]
}

RippleEase(t) {
    global Cfg
    switch Cfg["Easing"] {
        case 1: return t
        case 3: return 1 - (1 - t) ** 5
    }
    return 1 - (1 - t) ** 3
}

; UpdateLayeredWindow both MOVES and PAINTS in one call, so there is no separate
; WinMove -- and no frame where the ring is in the wrong place.
RippleBlit(rp, alpha) {
    global RipBufSize
    static bf    := Buffer(4, 0)
    static ptDst := Buffer(8, 0)
    static szWin := Buffer(8, 0)
    static ptSrc := Buffer(8, 0)

    NumPut("UChar", 0, bf, 0)          ; BlendOp = AC_SRC_OVER
    NumPut("UChar", 0, bf, 1)          ; BlendFlags
    NumPut("UChar", alpha, bf, 2)      ; SourceConstantAlpha -- this IS the fade
    NumPut("UChar", 1, bf, 3)          ; AlphaFormat = AC_SRC_ALPHA (keeps AA edges)

    NumPut("Int", Round(rp.cx - RipBufSize / 2), ptDst, 0)
    NumPut("Int", Round(rp.cy - RipBufSize / 2), ptDst, 4)
    NumPut("Int", RipBufSize, szWin, 0)
    NumPut("Int", RipBufSize, szWin, 4)

    DllCall("UpdateLayeredWindow", "Ptr", rp.hwnd, "Ptr", 0, "Ptr", ptDst, "Ptr", szWin,
            "Ptr", rp.hdc, "Ptr", ptSrc, "UInt", 0, "Ptr", bf, "UInt", 2)   ; ULW_ALPHA

    rp.bx := rp.cx, rp.by := rp.cy   ; lets a parked ring detect it needs re-blitting
}
