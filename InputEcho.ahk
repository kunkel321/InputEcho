; ==============================================================================
; InputEcho --  Version date: 8-13-2026
; AHK Forums    https://www.autohotkey.com/boards/viewtopic.php?f=83&t=139991
; GitHub        https://github.com/kunkel321/InputEcho
; Keyboard portion based on the original On-Screen Keyboard by Jon
; https://autohotkey.com/docs/scripts/KeyboardOnScreen.htm
; Converted to AHK v2 by kunkel321 using Claude AI.
; Code also reworked with ChatGPT.
;
; Echoes your physical input back onto the screen, so that someone watching a
; recording can see what you are actually doing. Two displays, one process:
;
;   KEYBOARD -- a mock keyboard along the bottom of the screen whose keys light up
;   as you press them. Doubles as a touch-typing aid: you can watch your hands on
;   screen instead of looking down at the real keyboard.
;
;   MOUSE CLICKS -- an animated ring at the cursor on every click, scroll and drag.
;   The keyboard's mouse block already says WHICH button; the ring says WHERE, which
;   is the half a recording loses. See ClickRipple.ahk for how it encodes button
;   identity and press-versus-release.
;
; Either can run without the other; both are toggled from the tray menu or by
; hotkey. Appearance is fully configurable through two settings panels, stored in
; InputEchoSettings.ini beside this script.
;
; Ctrl+Alt+K keyboard on/off       Alt+Up / Alt+Down     transparency
; Ctrl+Alt+M mouse clicks on/off   Alt+Wheel             transparency
; Drag to move. Double-click to hide. Ctrl+Esc exits.
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

; 8-13-2026 MERGED with the click-ripple effect (ClickRipple.ahk). One process, not
; two, for two reasons that are really the same reason:
;   Z-ORDER. Both parts must re-assert topmost to stay visible over menus and
;   capture overlays. As separate scripts they RACE: each raises itself above the
;   other on its own timer, forever, and whichever lost the last tick flickers.
;   Combined, RaiseAll() does one ordered pass -- keyboard first, ripples second --
;   so ripples land above the keyboard deterministically and nothing contends.
;   HOOKS. Same shape, worse stakes. Two InstallMouseHook(true,true) timers fight
;   for front-of-chain, and losing that means MISSING KEYSTROKES, not just being
;   briefly covered. One script = one hook set = nothing to race.
; Settings now live in an INI beside the script, edited through two panels off the
; tray menu. See the SETTING SPEC: it is the single source of truth, driving
; defaults, INI I/O, panel construction and tooltips all at once.

#Include CtrlToolTip.ahk
#Include ClickRipple.ahk

; AHK v2 defaults Mouse coordinates to CLIENT, not Screen. The ripple positions its
; layered windows in absolute screen pixels, so without this every ring lands offset
; by the active window's client origin -- and by a DIFFERENT amount per window, which
; is why clicking the keyboard (parked at the bottom of the screen, so a large client
; Y) threw rings upward rather than leftward. Set here in the auto-execute section so
; every hotkey thread inherits it.
CoordMode("Mouse", "Screen")

TraySetIcon("shell32.dll",45) ; Icon of a brownish square with a key image.
A_IconTip := "InputEcho" (A_IsAdmin ? " (admin)" : "")  ; elevation at a glance
^Esc::ExitApp ; Ctrl+Esc to kill script

; ==============================================================================
;  SETTING SPEC -- the single source of truth
;
;  Every user-facing setting is described exactly once, here. This one table
;  drives ALL of: the default value, the INI key and section, the type conversion
;  on read, the control that appears in the settings panel, and the tooltip on
;  that control. Adding a setting means adding one row -- there is no second place
;  to update and therefore no way for the pieces to fall out of step.
;
;  Fields:
;    key    Cfg key and INI key (same name in both, deliberately)
;    sec    INI section
;    type   int | float | bool | color | str | choice
;    def    default value
;    min/max, scale   slider bounds; scale 10 means the slider carries 10x the
;                     value, so a float setting can ride an integer control
;    unit   suffix on the live value readout
;    panel  "kb" | "mouse" | "" (state-only, never shown)
;    live   true  = takes effect on Save
;           false = baked into the layout at startup; Save offers a restart
;    label / tip
; ==============================================================================
global SettingSpec := [
    ; ---- state (not shown in any panel) ----
    {key:"ShowKeyboard", sec:"State", type:"bool", def:true,  panel:"", live:true},
    {key:"ShowMouse",    sec:"State", type:"bool", def:true,  panel:"", live:true},

    ; ---- keyboard ----
    {key:"FontSize", sec:"Keyboard", type:"int", def:10, min:6, max:24, scale:1, unit:" pt",
     panel:"kb", live:false, label:"Font size",
     tip:"Drives the ENTIRE layout, not just the text -- key width, spacing and height are all "
       . "multiples of it. Raising this makes the whole keyboard bigger, so treat it as the "
       . "master size control."},

    {key:"FontName", sec:"Keyboard", type:"str", def:"Verdana",
     panel:"kb", live:false, label:"Font name",
     tip:"Leave empty for the system default. A wide face like Verdana keeps single-letter "
       . "labels centred and readable when the keyboard is scaled down for a recording."},

    {key:"FontStyle", sec:"Keyboard", type:"str", def:"Bold",
     panel:"kb", live:false, label:"Font style",
     tip:"Space-separated, e.g. 'Bold' or 'Italic Underline'. Bold survives video compression "
       . "noticeably better than regular at small sizes."},

    {key:"CondensedMode", sec:"Keyboard", type:"bool", def:false,
     panel:"kb", live:false, label:"Condensed mode",
     tip:"Shrinks key HEIGHT only -- width, spacing and font are identical. Off gives roughly "
       . "physical-keyboard proportions, which is what you want for touch-typing practice. On "
       . "gives a short overlay that stays out of the way during a screencast."},

    {key:"Monitor", sec:"Keyboard", type:"int", def:0, min:0, max:4, scale:1, unit:"",
     panel:"kb", live:false, label:"Monitor",
     tip:"Which monitor the keyboard parks itself along the bottom of. 0 means the primary one."},

    {key:"KeyBackColor", sec:"Keyboard", type:"color", def:0xE6E6E6,
     panel:"kb", live:false, label:"Key fill",
     tip:"Resting fill for a key that isn't pressed. Also the far end of every fade ramp, so a "
       . "released key travels back to exactly this color."},

    {key:"KeyActiveColor", sec:"Keyboard", type:"color", def:0xFF3D3D,
     panel:"kb", live:true, label:"Key pressed",
     tip:"Fill for a key while it is held. The bigger the contrast against the resting fill, the "
       . "more legible fast typing is -- this is the one color a viewer actually tracks."},

    {key:"KeyTextColor", sec:"Keyboard", type:"color", def:0x000000,
     panel:"kb", live:false, label:"Key label",
     tip:"Label text color. Needs to stay readable against BOTH the resting fill and the pressed "
       . "fill, which is the constraint people usually forget when picking a dark active color."},

    {key:"MouseBackColor", sec:"Keyboard", type:"color", def:0xE6E6E6,
     panel:"kb", live:false, label:"Mouse block fill",
     tip:"Resting fill for the L / R / wheel blocks. Their ACTIVE colors are the ripple colors, "
       . "set over in Mouse Settings, so the on-screen button and the ring it draws always agree."},

    {key:"FadeSteps", sec:"Keyboard", type:"int", def:12, min:1, max:30, scale:1, unit:"",
     panel:"kb", live:true, label:"Fade steps",
     tip:"How many colors a released key steps through on its way back to rest. More is smoother, "
       . "fewer is chunkier. Set to 1 to switch fading off entirely and snap straight back."},

    {key:"FadeDuration", sec:"Keyboard", type:"int", def:400, min:50, max:2000, scale:1, unit:" ms",
     panel:"kb", live:true, label:"Fade duration",
     tip:"Total time for a released key to travel the whole ramp. Long fades look elegant but "
       . "smear fast typing into a wash of half-lit keys -- shorten it if you type quickly on camera."},

    {key:"RestrikeBlinkMs", sec:"Keyboard", type:"int", def:45, min:0, max:200, scale:1, unit:" ms",
     panel:"kb", live:true, label:"Restrike blink",
     tip:"When a key is pressed again while still fading -- the double 'o' in 'book' -- it snaps to "
       . "the resting color for this long first. Without it the two strikes merge into one long "
       . "glow and the viewer sees a single press. 0 disables."},

    {key:"Transparency", sec:"Keyboard", type:"int", def:255, min:30, max:255, scale:1, unit:"",
     panel:"kb", live:true, label:"Opacity",
     tip:"Overall keyboard opacity: 255 is solid, lower is more see-through. Alt+Up/Down and "
       . "Alt+Wheel adjust this live while the keyboard is focused."},

    {key:"TransparencyStep", sec:"Keyboard", type:"int", def:15, min:5, max:50, scale:1, unit:"",
     panel:"kb", live:true, label:"Opacity step",
     tip:"How far each Alt+Up / Alt+Wheel notch moves the opacity. Larger gets you there faster; "
       . "smaller gives finer control on camera."},

    {key:"TransparencyMin", sec:"Keyboard", type:"int", def:30, min:10, max:255, scale:1, unit:"",
     panel:"kb", live:true, label:"Opacity floor",
     tip:"Lower limit for the above, so you can't accidentally fade the keyboard to invisible and "
       . "then be unable to find it to fade it back."},

    {key:"HookFrequency", sec:"Keyboard", type:"int", def:3000, min:500, max:10000, scale:1, unit:" ms",
     panel:"kb", live:true, label:"Hook re-assert",
     tip:"How often the low-level hooks are force-reinstalled to regain FIRST position in the hook "
       . "chain. This is what stops other scripts from eating key combos before we can show them. "
       . "Lower means fewer missed combos but more churn."},

    ; The three "hides" routes share a row -- they are one decision with three
    ; switches, and stacking them vertically made them read as unrelated options.
    {key:"DblClickHides", sec:"Keyboard", type:"bool", def:true, bw:138,
     panel:"kb", live:true, label:"Double-click hides",
     tip:"Double-clicking anywhere on the keyboard hides it. Ctrl+Alt+K or the tray brings it back."},

    {key:"RightClickHides", sec:"Keyboard", type:"bool", def:false, bw:138, sameRow:true,
     panel:"kb", live:true, label:"Right-click hides",
     tip:"Same, for right-click. Off by default because right-clicking the keyboard is easy to do "
       . "by accident while dragging it into position."},

    {key:"EscHides", sec:"Keyboard", type:"bool", def:true, bw:138, sameRow:true,
     panel:"kb", live:true, label:"Esc key hides",
     tip:"Pressing Esc while the keyboard is the ACTIVE window hides it. Only fires when the "
       . "keyboard itself has focus, so it won't swallow Esc from the app you're demonstrating -- "
       . "but it's easy to hit right after clicking the keyboard to drag it."},

    {key:"ToggleMouseHotkey", sec:"Mouse", type:"str", def:"^!m",
     panel:"mouse", live:false, label:"Toggle hotkey",
     tip:"Turns the click rings on and off from anywhere, the way Ctrl+Alt+K does for the "
       . "keyboard. Handy mid-recording when a section doesn't need them. AHK syntax: "
       . "^ Ctrl, ! Alt, + Shift, # Win."},

    {key:"ToggleMouseHotkeyLabel", sec:"Mouse", type:"str", def:"Ctrl+Alt+M",
     panel:"mouse", live:false, label:"Hotkey label",
     tip:"Only the text shown beside the tray item. Cosmetic, but keep it in step with the "
       . "hotkey above or the menu will lie to you."},

    {key:"ToggleHotkey", sec:"Keyboard", type:"str", def:"^!k",
     panel:"kb", live:false, label:"Toggle hotkey",
     tip:"AHK syntax: ^ Ctrl, ! Alt, + Shift, # Win. Change it if Ctrl+Alt+K collides with "
       . "something. A bare key is a bad idea here -- the keyboard runs while you type."},

    {key:"ToggleHotkeyLabel", sec:"Keyboard", type:"str", def:"Ctrl+Alt+K",
     panel:"kb", live:false, label:"Hotkey label",
     tip:"Only the text shown beside the tray item. Purely cosmetic, but keep it in step with the "
       . "hotkey above or the menu will lie to you."},

    ; ---- mouse ----
    {key:"StartR", sec:"Mouse", type:"int", def:6, min:2, max:40, scale:1, unit:" px",
     panel:"mouse", live:true, label:"Small radius",
     tip:"The tight end of the animation: where a press finishes contracting and a release begins "
       . "blooming. Larger keeps a visible ring sitting over the thing you clicked; smaller "
       . "collapses almost to a point."},

    {key:"EndR", sec:"Mouse", type:"int", def:72, min:20, max:160, scale:1, unit:" px",
     panel:"mouse", live:true, label:"Large radius",
     tip:"The wide end: where a press begins and a release finishes. Bigger pulls the eye from "
       . "further across the screen, but sweeps over more of the surrounding interface."},

    {key:"DurationIn", sec:"Mouse", type:"int", def:312, min:100, max:800, scale:1, unit:" ms",
     panel:"mouse", live:true, label:"In duration",
     tip:"How long a press takes to contract. Only seen in full when you HOLD the button -- an "
       . "ordinary quick click is released long before this elapses and finishes on Snap-in instead."},

    {key:"Duration", sec:"Mouse", type:"int", def:800, min:150, max:1200, scale:1, unit:" ms",
     panel:"mouse", live:true, label:"Out duration",
     tip:"How long a release takes to bloom outward. This is the part viewers actually watch, so it "
       . "carries most of the effect's character. Longer reads as graceful, shorter as crisp."},

    {key:"SnapMs", sec:"Mouse", type:"int", def:100, min:30, max:400, scale:1, unit:" ms",
     panel:"mouse", live:true, label:"Snap-in",
     tip:"For clicks released before the contraction finishes -- which is nearly all of them. The "
       . "ring hurries the rest of the way in over this long, then blooms, so the complete shape "
       . "always plays. Raise if fast clicks look abrupt; lower if they lag your finger."},

    {key:"ThinPen", sec:"Mouse", type:"int", def:5, min:1, max:12, scale:1, unit:" px",
     panel:"mouse", live:true, label:"Thin pen",
     tip:"Stroke weight of the full circle at its widest. The circle is the locator -- it answers "
       . "WHERE. Keep it light enough that it never obscures the control you just clicked."},

    {key:"ThickRatio", sec:"Mouse", type:"float", def:5.0, min:10, max:60, scale:10, unit:"x",
     panel:"mouse", live:true, label:"Thick ratio",
     tip:"How many times heavier the arc is than the circle. The arc is the identifier -- it answers "
       . "WHICH BUTTON. Shape survives video compression far better than color, so err heavy."},

    {key:"ArcSweep", sec:"Mouse", type:"int", def:100, min:40, max:320, scale:1, unit:" deg",
     panel:"mouse", live:true, label:"Arc sweep L/R",
     tip:"How much of the circle the heavy arc covers for left and right clicks. 180 splits the ring "
       . "cleanly in half. Below about 120 it stops reading as a SIDE and starts reading as a blob "
       . "stuck to the ring."},

    {key:"WheelSweep", sec:"Mouse", type:"int", def:95, min:20, max:200, scale:1, unit:" deg",
     panel:"mouse", live:true, label:"Wheel sweep",
     tip:"The same, for wheel and middle click. Keep it clearly SHORTER than the button sweep: the "
       . "difference in length is a second cue, on top of position, that this wasn't a button press."},

    {key:"AlphaPow", sec:"Mouse", type:"float", def:0.6, min:5, max:40, scale:10, unit:"",
     panel:"mouse", live:true, label:"Fade power",
     tip:"Shape of the fade during the bloom. Low fades evenly from the first frame. High holds near "
       . "full brightness then drops away late, so the ring snaps off rather than dissolving."},

    {key:"RingOpacity", sec:"Mouse", type:"int", def:50, min:10, max:100, scale:1, unit:"%",
     panel:"mouse", live:true, label:"Ring opacity",
     tip:"Transparency of the thin locator circle. Dropping this lets the circle guide the eye "
       . "without competing with the arc -- often the single biggest improvement to how calm the "
       . "effect feels over a long recording."},

    {key:"ArcOpacity", sec:"Mouse", type:"int", def:50, min:10, max:100, scale:1, unit:"%",
     panel:"mouse", live:true, label:"Arc opacity",
     tip:"Transparency of the heavy identifying arc. Keep it at or above the ring: this is the stroke "
       . "carrying the which-button information, and the first thing lost at low bitrate."},

    {key:"FrameMs", sec:"Mouse", type:"int", def:22, min:10, max:40, scale:1, unit:" ms",
     panel:"mouse", live:true, label:"Frame interval",
     tip:"Milliseconds between redraws. 22 is roughly 45fps. Recordings are usually 30fps, so below "
       . "about 20 you spend CPU that never reaches the video -- and compete with the recorder for "
       . "the same machine."},

    {key:"RaiseMs", sec:"Mouse", type:"int", def:80, min:16, max:500, scale:1, unit:" ms",
     panel:"mouse", live:true, label:"Re-assert top",
     tip:"How often the keyboard and rings re-claim the front of the topmost window band. Lower it if "
       . "menus or capture overlays briefly draw over the animation."},

    {key:"Easing", sec:"Mouse", type:"choice", def:2,
     choices:["Linear", "Ease-out cubic", "Ease-out quint"],
     panel:"mouse", live:true, label:"Easing",
     tip:"How the radius moves over time. Linear travels at constant speed. The ease-out curves start "
       . "fast and settle, which reads as a snap rather than a glide."},

    {key:"Color1", sec:"Mouse", type:"color", def:0x1048FF,
     panel:"mouse", live:false, label:"Left / wheel color",
     tip:"Used by the left-click, middle-click and wheel rings AND by the matching blocks on the "
       . "on-screen keyboard, so the two can never disagree. Shape already identifies the button, so "
       . "pick for LUMINANCE contrast against what you're demonstrating, not just a different hue."},

    {key:"Color2", sec:"Mouse", type:"color", def:0xBA7517,
     panel:"mouse", live:false, label:"Right color",
     tip:"Right-click ring and the on-screen R block, when the two-color box below is ticked. Amber "
       . "beats red here: 4:2:0 video subsamples chroma and saturated red smears worse than anything."},

    {key:"TwoColors", sec:"Mouse", type:"bool", def:false,
     panel:"mouse", live:false, label:"Second color for right click",
     tip:"Gives right-click its own hue on top of its own arc position, on both the ring and the "
       . "on-screen block. Redundant cues survive colorblindness and bad bitrates, but a single "
       . "color looks more cohesive. Worth trying both."},

    {key:"RoundCaps", sec:"Mouse", type:"bool", def:true,
     panel:"mouse", live:true, label:"Round arc caps",
     tip:"Rounds the ends of the heavy arc so it tapers into the thin circle. Unticked, the thick "
       . "stroke butts against the thin one and leaves a square step -- most visible at high ratios."},

    {key:"HoldRing", sec:"Mouse", type:"bool", def:true,
     panel:"mouse", live:true, label:"Keep ring while button held",
     tip:"Ticked: the contracted ring parks at the pointer and FOLLOWS it while the button is down, "
       . "then blooms where you let go -- so a drag is visible along its whole path. Unticked: it "
       . "fades once contracted and the release blooms separately."},

    {key:"KeepOnTop", sec:"Mouse", type:"bool", def:true,
     panel:"mouse", live:true, label:"Stay above other topmost windows",
     tip:"Topmost is a BAND, not a rank: within it the most recently shown window wins. Without this, "
       . "any topmost window opened after a ripple -- a menu, a capture overlay -- draws over it."},

    ; panel:"both" -- appears on BOTH settings panels but is stored once, so the two
    ; copies are the same setting and cannot disagree.
    {key:"ShowTips", sec:"General", type:"bool", def:true,
     panel:"both", live:true, label:"Show tooltips",
     tip:"Untick to stop these hover explanations appearing. They're aimed at someone meeting the "
       . "settings for the first time; once the numbers mean something to you they're mostly in "
       . "the way. Takes effect the next time a panel is opened."},

    {key:"IgnorePanel", sec:"Mouse", type:"bool", def:true,
     panel:"mouse", live:true, label:"Ignore clicks on settings panels",
     tip:"Suppresses rings over this window, so adjusting settings doesn't paint circles across the "
       . "controls you're reading."}
]

global Cfg := Map()
global IniPath := A_ScriptDir . "\InputEchoSettings.ini"
global SettingsGui := 0, SettingsCtrls := Map(), SettingsPanelKind := ""
; The hot path (every mouse click, from a hook thread) compares against a plain
; HWND rather than reaching into the Gui object. A destroyed Gui is still a live,
; truthy object, so `!SettingsGui` does NOT catch it and `.Hwnd` throws -- and an
; exception raised on every click, from a hook thread, is effectively unkillable.
global SettingsHwnd := 0
; A restart-needed change made on ONE panel has to survive a switch to the other,
; or you could change the font, hop to Mouse, save there, and never be told the
; keyboard needs rebuilding. Cleared only when the prompt is actually shown.
global PendingRestart := false
global SuspendRipples := false

;---- Configuration Section
; Values now come from the INI via the SETTING SPEC above. These k_*
; globals are a one-way BRIDGE: read once at startup so the whole body of the
; original script keeps working untouched. Anything that changes them at runtime
; must go through ApplyLive() so the bridge and Cfg can't drift apart.
LoadSettings()

k_FontSize := Cfg["FontSize"]
k_FontName := Cfg["FontName"]
k_FontStyle := Cfg["FontStyle"]
k_CondensedMode := Cfg["CondensedMode"]

; Cfg stores colors as INTEGERS, but everything downstream of here wants a bare
; 6-char hex STRING: the fills are concatenated into Gui options ("Background" .
; color) and BuildFadeGradient slices them with SubStr(hex, 1, 2). Hand it an
; integer and it slices the DECIMAL digits instead -- 0xE6E6E6 arrives as
; "15132390", slices to 15/13/23, and every ramp marches toward near-black.
k_KeyBackColor := Format("{:06X}", Cfg["KeyBackColor"])
k_KeyActiveColor := Format("{:06X}", Cfg["KeyActiveColor"])
k_MouseBackColor := Format("{:06X}", Cfg["MouseBackColor"])
k_KeyTextColor := Format("{:06X}", Cfg["KeyTextColor"])

; The mouse block's active fills are the RIPPLE colors, so an on-screen L or R
; button and the ring it draws are never a different color. Color2 only applies
; when TwoColors is on; otherwise both buttons use Color1, matching the rings.
k_MouseActiveColor  := Format("{:06X}", Cfg["Color1"])
k_MouseActiveColorR := Format("{:06X}", Cfg["TwoColors"] ? Cfg["Color2"] : Cfg["Color1"])

k_FadeSteps := Cfg["FadeSteps"]
k_FadeDuration := Cfg["FadeDuration"]
k_RestrikeBlinkMs := Cfg["RestrikeBlinkMs"]
k_DblClickHides := Cfg["DblClickHides"]
k_RightClickHides := Cfg["RightClickHides"]
k_EscHides := Cfg["EscHides"]

; Per-step dwell = the timer period. Guard against divide-by-zero when fade is off.
k_FadeStepMs := (k_FadeSteps > 1) ? Max(15, Round(k_FadeDuration / (k_FadeSteps - 1))) : 0
; Precompute the ramps once. Three now: keys, mouse-L/wheel, and mouse-R -- the
; last is a separate ramp because R can have its own color.
k_KeyFadeColors := BuildFadeGradient(k_KeyActiveColor, k_KeyBackColor, k_FadeSteps)
k_MouseFadeColors := BuildFadeGradient(k_MouseActiveColor, k_MouseBackColor, k_FadeSteps)
k_MouseFadeColorsR := BuildFadeGradient(k_MouseActiveColorR, k_MouseBackColor, k_FadeSteps)

k_ToggleHotkey := Cfg["ToggleHotkey"]
k_ToggleHotkeyLabel := Cfg["ToggleHotkeyLabel"]

k_MenuItemHide := "Hide Keyboard -- " . k_ToggleHotkeyLabel
k_MenuItemShow := "Show Keyboard -- " . k_ToggleHotkeyLabel

k_Monitor := (Cfg["Monitor"] > 0) ? Cfg["Monitor"] : ""  ; 0 = primary

; Transparency: Alt+Up / Alt+Down and Alt+WheelUp / Alt+WheelDown adjust the
; keyboard's overall opacity, but only while the keyboard window is focused.
; Up / WheelUp = more opaque; Down / WheelDown = more see-through. Flip the sign
; of k_TransparencyStep at registration if you prefer the opposite direction.
k_Transparency := Cfg["Transparency"]
k_TransparencyStep := Cfg["TransparencyStep"]
k_TransparencyMin := Cfg["TransparencyMin"]

; OSK will reestablish keyboard hooks with this frequency (millisecs) to ensre that
; other apps don't "eat" key-combos.  This is useful for screencasts.  Rehooks only
; occur if/when the OSK gui is not hidden. 
K_HookFrequency := Cfg["HookFrequency"]

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
;
; DELIBERATELY still says OnScreenKeyboard after the 8-13-2026 rename to InputEcho.
; This string is a CROSS-PROCESS CONTRACT, not a display name: ScreenSnip and friends
; match on it from outside. Renaming it to match the app would break them silently --
; no error anywhere, the suppressed-button highlights would just stop arriving. Same
; goes for the RegisterWindowMessage string further down, which is matched by text in
; every process that uses it.
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

;---- Register the global show/hide toggles (both work while their display is hidden)
Hotkey(k_ToggleHotkey, ToggleKeyboard)
Hotkey(Cfg["ToggleMouseHotkey"], ToggleMouse)

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
    global k_IsVisible, Cfg
    ; While EVERYTHING is hidden, front-of-chain position is worthless -- and every
    ; force-reinstall carries a microsecond gap where a keystroke could slip past
    ; unhighlighted. Skip the churn until something is shown again; ShowKeyboard()
    ; calls us immediately on unhide so there's no 3-second lag.
    ; NOTE the second condition: ripples can run with the keyboard hidden, and they
    ; need front-of-chain just as much (a suppressed button never reaches us).
    if (!k_IsVisible && !Cfg["ShowMouse"])
        return
    InstallKeybdHook(true, true)   ; true, true = install + FORCE reinstall
    InstallMouseHook(true, true)
}
JumpHooksToFront()
SetTimer(JumpHooksToFront, K_HookFrequency)

;---- Tray menu setup
; Two independent CHECKBOXES rather than a three-way mode: the keyboard and the
; ripples are separate displays that happen to share a process, and forcing them
; onto one "both/either" control would hide that.
TrayMenu := A_TrayMenu
k_StatusLine := "InputEcho " (A_IsAdmin ? "(admin)" : "(NOT admin)")
TrayMenu.Insert("1&", k_StatusLine, (*) => "")
TrayMenu.Disable(k_StatusLine)
TrayMenu.Insert("2&")                       ; separator under the status line

k_MenuKeyboard := "Show Keyboard`t" . k_ToggleHotkeyLabel
k_MenuMouse    := "Show Mouse Clicks`t" . Cfg["ToggleMouseHotkeyLabel"]
TrayMenu.Insert("3&", k_MenuKeyboard, ToggleKeyboard)
TrayMenu.Insert("4&", k_MenuMouse, ToggleMouse)
TrayMenu.Insert("5&")
TrayMenu.Insert("6&", "Keyboard Settings", (*) => ShowSettings("kb"))
TrayMenu.Insert("7&", "Mouse Settings", (*) => ShowSettings("mouse"))
TrayMenu.Insert("8&", "Open ini file", (*) => OpenIniFile())
TrayMenu.Insert("9&")
TrayMenu.Default := k_MenuKeyboard
SyncTrayChecks()

;---- Drop AHK's stock Pause and Suspend items.
; Neither has a coherent meaning here, and Pause actively looks broken. Pause
; freezes TIMERS while leaving hotkeys live -- so a paused script still lights keys
; and still shows a ring, but the fade timer and the animation timer never tick.
; The key stays red forever and the ring hangs at its opening radius. It looks like
; a crash; it isn't. (Un-pausing resumes the timers and everything finishes cleanly.)
; Suspend is the mirror image -- hotkeys off, timers on -- which is coherent but
; redundant, and worse than the real toggles because it would also kill the
; Ctrl+Alt+K / Ctrl+Alt+M hotkeys you'd use to get back.
; Anyone reaching for either of these wants "Show Keyboard" or "Show Mouse Clicks".
; Deleted by name inside try, since these labels belong to AHK, not to us.
for item in ["&Pause Script", "&Suspend Hotkeys"]
    try TrayMenu.Delete(item)

;---- Ripple engine + Z-order coordination
RippleInit()
Hotkey("~*MButton", MButtonPress)
Hotkey("~*MButton up", MButtonRelease)
OnExit(RippleShutdown)

; Slow heartbeat for the keyboard's own topmost claim. While ripples animate,
; RippleTick calls RaiseAll() at frame rate instead, so this only has to cover the
; idle case -- no point re-asserting 45 times a second when nothing is moving.
SetTimer(RaiseAll, 2000)

if !Cfg["ShowKeyboard"]
    HideKeyboard()

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
    global buttons, buttonNormalColors, fadingKeys, k_KeyActiveColor
    global k_MouseActiveColor, k_MouseActiveColorR
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
        ; RButton may carry its own color (see the Color1/Color2 note in the
        ; bridge), so the mouse branch has to ask which button it is.
        color := isMouse
               ? ((buttonKey = "RButton") ? k_MouseActiveColorR : k_MouseActiveColor)
               : k_KeyActiveColor
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
    global buttons, buttonNormalColors, fadingKeys, k_KeyFadeColors
    global k_MouseFadeColors, k_MouseFadeColorsR
    global k_FadeSteps, k_FadeStepMs, k_KeyBackColor

    if !buttons.Has(buttonKey)
        return

    ; Fade disabled -> revert instantly to the key's stored normal color.
    if (k_FadeSteps <= 1) {
        PaintKey(buttonKey, buttonNormalColors.Has(buttonKey) ? buttonNormalColors[buttonKey] : k_KeyBackColor)
        return
    }

    ramp := isMouse
          ? ((buttonKey = "RButton") ? k_MouseFadeColorsR : k_MouseFadeColors)
          : k_KeyFadeColors
    fadingKeys[buttonKey] := { colors: ramp, idx: 1 }
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
; The merge point: one passthrough hotkey feeds the on-screen key AND the ripple.
; This is why combining was worth doing -- a separate ripple script would need its
; own mouse hook competing with this one for front-of-chain.
KeyPress(ThisHotkey) {
    global buttons
    buttonKey := ResolveButtonKey(A_ThisHotkey)
    if buttons.Has(buttonKey)
        SetKeyActive(buttonKey, true, IsMouseKey(buttonKey))
    if (buttonKey = "LButton")
        RippleDown("L")
    else if (buttonKey = "RButton")
        RippleDown("R")
}

;---- Key/button UP: begin the fade. Returns immediately -- never blocks.
KeyRelease(ThisHotkey) {
    global buttons
    buttonKey := ResolveButtonKey(A_ThisHotkey)
    if buttons.Has(buttonKey)
        StartKeyFade(buttonKey, IsMouseKey(buttonKey))
    if (buttonKey = "LButton")
        RippleUp("L")
    else if (buttonKey = "RButton")
        RippleUp("R")
}

;---- Middle button: light BOTH wheel arrows at once, rather than adding a control
; that exists only for this. It reads correctly on its own -- a press that is neither
; up nor down -- and it happens to be the same statement the ring makes, which draws
; its thick arc at both top AND bottom for a middle click. The two displays say the
; same thing in their own idioms.
;
; Unlike the wheel, MButton has a real down/up pair, so there is no timed flash here:
; both arrows simply stay lit for as long as the button is held.
MButtonPress(ThisHotkey) {
    global buttons
    for k in ["WheelUp", "WheelDown"]
        if buttons.Has(k)
            SetKeyActive(k, true, true)
    RippleDown("M")
}

MButtonRelease(ThisHotkey) {
    global buttons
    for k in ["WheelUp", "WheelDown"]
        if buttons.Has(k)
            StartKeyFade(k, true)
    RippleUp("M")
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
    RippleWheel(thisKey = "WheelUp" ? "WU" : "WD")
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
    ; wParam already means exactly what the ripple needs: 1 = press edge, 0 =
    ; release edge. So a button ScreenSnip suppresses still gets its full heartbeat
    ; -- which matters, because Ctrl+RClick-drag is the gesture most worth showing
    ; and the one our own hook can never see.
    kind := (buttonKey = "LButton") ? "L" : "R"
    if wParam {
        SetKeyActive(buttonKey, true, IsMouseKey(buttonKey))   ; light it
        RippleDown(kind)
    } else {
        StartKeyFade(buttonKey, IsMouseKey(buttonKey))         ; fade it out
        RippleUp(kind)
    }
}

;---- Show / hide / toggle the keyboard. All three entry points (tray item, Esc,
; and the global hotkey) route through these so k_IsVisible and the menu label
; can never drift out of sync.
ShowKeyboard() {
    global MyGui, k_IsVisible, Cfg
    if k_IsVisible
        return
    MyGui.Show()
    Cfg["ShowKeyboard"] := true
    SaveSettings()
    SyncTrayChecks()
    k_IsVisible := true
    ; Hook jumps are paused while hidden (see JumpHooksToFront), so grab the front
    ; of the hook chain NOW rather than waiting up to 3s for the next timer tick.
    JumpHooksToFront()
}

HideKeyboard() {
    global MyGui, k_IsVisible, Cfg
    if !k_IsVisible
        return
    MyGui.Hide()
    Cfg["ShowKeyboard"] := false
    SaveSettings()
    SyncTrayChecks()
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
    ; OnMessage is PROCESS-wide, so this fires for every window we own -- including
    ; the settings panels. Without this guard, a click anywhere in a settings panel
    ; threw the KEYBOARD into Windows' caption-drag modal loop, which takes mouse
    ; capture: the click got swallowed (so everything needed clicking twice) and
    ; tooltip tracking died. Harmless while this script owned exactly one window;
    ; the moment a second one existed it broke both. The dbl-click and right-click
    ; handlers below already had the same guard.
    if (hwnd != MyGui.Hwnd)
        return
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
    global buttons, MyGui, k_IsVisible, k_EscHides

    if buttons.Has("Escape")
        StartKeyFade("Escape")

    ; Original behavior: Esc hides the keyboard when it's the active window. Now
    ; optional, like the double-click and right-click routes -- all three are easy to
    ; trigger by accident while dragging the keyboard into position mid-recording.
    if k_EscHides && WinActive("ahk_id " MyGui.Hwnd) && k_IsVisible
        HideKeyboard()
}

;---- Transparency helpers
; HotIf callback: the transparency hotkeys are live only when the keyboard is focused.
IsKbFocused(*) {
    global MyGui
    return WinActive("ahk_id " MyGui.Hwnd)
}

;---- The ONE place the keyboard's opacity is set.
; DetectHiddenWindows is the point of this function. WinSetTransparent matches by
; window, and a HIDDEN Gui is not matched unless hidden windows are detectable --
; it is Off by default. So saving MOUSE settings while "Show Keyboard" was unchecked
; threw "Target window not found" from the middle of ApplyLive, which aborted the
; rest of that function: round caps, buffer resizing and everything else below the
; throw were silently skipped. One bad line made unrelated settings look broken.
; DetectHiddenWindows is per-thread, so this is set and restored locally.
SetKbTransparency(alpha) {
    global MyGui
    prev := A_DetectHiddenWindows
    DetectHiddenWindows(true)
    try {
        if (alpha >= 255)
            WinSetTransparent("Off", "ahk_id " MyGui.Hwnd)  ; fully opaque (drops layered style)
        else
            WinSetTransparent(alpha, "ahk_id " MyGui.Hwnd)
    }
    DetectHiddenWindows(prev)
}

; Nudge the keyboard's overall opacity by delta, clamped to [k_TransparencyMin, 255].
AdjustTransparency(delta, *) {
    global Cfg, k_Transparency, k_TransparencyMin
    k_Transparency := Max(k_TransparencyMin, Min(255, k_Transparency + delta))
    ; Push it back into Cfg too, or Alt+Wheel and the settings panel disagree: the
    ; panel would still show the old value and Save would quietly undo your nudge.
    Cfg["Transparency"] := k_Transparency
    SetKbTransparency(k_Transparency)
}

;---- One predicate for "does this setting appear on this panel", used by the panel
; builder AND by the change-reader. They have to agree: if the builder shows a control
; the reader doesn't look at, edits to it vanish on Save.
InPanel(sp, kind) {
    return (sp.panel = kind) || (sp.panel = "both")
}

SpecFor(key) {
    global SettingSpec
    for sp in SettingSpec
        if (sp.key = key)
            return sp
    return 0
}

;---- Read the INI into Cfg, falling back to each spec default. IniRead always
; returns a STRING, so every value has to be converted by its declared type --
; skipping that is how "0" ends up truthy and a color ends up compared as text.
LoadSettings() {
    global SettingSpec, Cfg, IniPath
    MigrateOldIni()
    for sp in SettingSpec {
        raw := IniRead(IniPath, sp.sec, sp.key, "")
        if (raw = "") {
            Cfg[sp.key] := sp.def
            continue
        }
        switch sp.type {
            case "int":    Cfg[sp.key] := Integer(raw)
            case "choice": Cfg[sp.key] := Integer(raw)
            case "float":  Cfg[sp.key] := Float(raw)
            case "bool":   Cfg[sp.key] := (raw = "1" || raw = "true")
            case "color":  Cfg[sp.key] := Integer("0x" . StrReplace(StrReplace(raw, "0x"), "#"))
            default:       Cfg[sp.key] := raw
        }
    }
}

;---- The app was called OnScreenKeyboard until 8-13-2026. Carry a settings file
; from that era across on first run rather than silently reverting to defaults --
; the mouse values in particular took real tuning to arrive at. Runs once: after
; the copy the new file exists, so the guard never fires again. The old file is
; left in place deliberately, in case you go back.
MigrateOldIni() {
    global IniPath
    old := A_ScriptDir . "\OnScreenKeyboard.ini"
    if (!FileExist(IniPath) && FileExist(old))
        try FileCopy(old, IniPath)
}

SaveSettings() {
    global SettingSpec, Cfg, IniPath
    for sp in SettingSpec {
        v := Cfg[sp.key]
        switch sp.type {
            case "bool":  out := v ? "1" : "0"
            case "color": out := Format("{:06X}", v)
            case "float": out := (v = Round(v)) ? Round(v) : Format("{:.2f}", v)
            default:      out := v
        }
        IniWrite(out, IniPath, sp.sec, sp.key)
    }
}

;---- Apply the settings that can change without rebuilding the layout. Anything
; woven into the GUI's geometry (font, condensed mode, monitor) is marked live:false
; in the spec and needs a restart instead -- pretending otherwise would leave the
; on-screen keys and the k_* bridge describing different keyboards.
ApplyLive() {
    global Cfg, MyGui, k_KeyActiveColor, k_KeyBackColor, k_MouseBackColor
    global k_MouseActiveColor, k_MouseActiveColorR
    global k_FadeSteps, k_FadeDuration, k_FadeStepMs, k_RestrikeBlinkMs
    global k_KeyFadeColors, k_MouseFadeColors, k_MouseFadeColorsR
    global k_DblClickHides, k_RightClickHides, k_EscHides, K_HookFrequency
    global k_Transparency, k_TransparencyStep, k_TransparencyMin

    k_KeyActiveColor    := Format("{:06X}", Cfg["KeyActiveColor"])
    k_MouseActiveColor  := Format("{:06X}", Cfg["Color1"])
    k_MouseActiveColorR := Format("{:06X}", Cfg["TwoColors"] ? Cfg["Color2"] : Cfg["Color1"])

    k_FadeSteps       := Cfg["FadeSteps"]
    k_FadeDuration    := Cfg["FadeDuration"]
    k_RestrikeBlinkMs := Cfg["RestrikeBlinkMs"]
    k_FadeStepMs      := (k_FadeSteps > 1) ? Max(15, Round(k_FadeDuration / (k_FadeSteps - 1))) : 0

    k_KeyFadeColors    := BuildFadeGradient(k_KeyActiveColor, k_KeyBackColor, k_FadeSteps)
    k_MouseFadeColors  := BuildFadeGradient(k_MouseActiveColor, k_MouseBackColor, k_FadeSteps)
    k_MouseFadeColorsR := BuildFadeGradient(k_MouseActiveColorR, k_MouseBackColor, k_FadeSteps)

    k_DblClickHides    := Cfg["DblClickHides"]
    k_RightClickHides  := Cfg["RightClickHides"]
    k_EscHides         := Cfg["EscHides"]
    k_TransparencyStep := Cfg["TransparencyStep"]
    k_TransparencyMin  := Cfg["TransparencyMin"]

    k_Transparency := Max(k_TransparencyMin, Min(255, Cfg["Transparency"]))
    SetKbTransparency(k_Transparency)

    if (K_HookFrequency != Cfg["HookFrequency"]) {
        K_HookFrequency := Cfg["HookFrequency"]
        SetTimer(JumpHooksToFront, K_HookFrequency)
    }

    RippleApplyCaps()
    RippleEnsureBuffers()
}

; ==============================================================================
;  Z-order: ONE ordered pass, which is the whole reason these two live in one
;  process. Keyboard first, then every live ripple, so the rings land above the
;  keyboard deterministically and both land above everything else. As separate
;  scripts this is a race with no winner -- each raises itself above the other
;  forever and whichever lost the last tick visibly flickers.
; ==============================================================================
RaiseAll(force := false) {
    global Cfg, MyGui, k_IsVisible, RipPool, SettingsHwnd
    static HWND_TOPMOST := -1
    static FLAGS := 0x0013   ; SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
    static lastRaise := 0
    if !Cfg["KeepOnTop"]
        return
    ; Stand down entirely while a settings panel is open. This pass exists so the
    ; keyboard survives menus and capture overlays DURING A RECORDING; while you are
    ; editing settings there is nothing to fight, and re-asserting does real damage:
    ; CtrlToolTip creates its tooltip window with dwExStyle 0 -- NOT topmost -- so
    ; forcing the topmost panel back to the front of the band every 80ms buried
    ; every tooltip behind the very panel it belonged to. Both windows keep their
    ; AlwaysOnTop style, so ordinary within-band ordering still puts the panel you
    ; just clicked in front of the keyboard.
    if SettingsHwnd
        return
    ; RippleTick calls this every animation frame (~45/sec), which is far more often
    ; than Z-order actually needs re-asserting. Throttle here rather than at the call
    ; sites so the slow idle timer and the fast animation path share one cadence.
    if (!force && A_TickCount - lastRaise < Cfg["RaiseMs"])
        return
    lastRaise := A_TickCount
    ; SWP_NOACTIVATE is essential: without it this steals focus on every pass,
    ; which is the one failure that ruins a recording outright.
    if k_IsVisible
        DllCall("SetWindowPos", "Ptr", MyGui.Hwnd, "Ptr", HWND_TOPMOST,
                "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", FLAGS)
    for rp in RipPool
        if rp.active
            DllCall("SetWindowPos", "Ptr", rp.hwnd, "Ptr", HWND_TOPMOST,
                    "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", FLAGS)
}

;---- Ripples skip clicks on our own settings panels and on the color dialog.
RippleSkipWindow(win) {
    global Cfg, SettingsGui, SuspendRipples
    if SuspendRipples
        return true
    if (!Cfg["IgnorePanel"] || !SettingsHwnd)
        return false
    return (win = SettingsHwnd)
}

; ==============================================================================
;  Tray
; ==============================================================================
SyncTrayChecks() {
    global TrayMenu, Cfg, k_MenuKeyboard, k_MenuMouse
    Cfg["ShowKeyboard"] ? TrayMenu.Check(k_MenuKeyboard) : TrayMenu.Uncheck(k_MenuKeyboard)
    Cfg["ShowMouse"]    ? TrayMenu.Check(k_MenuMouse)    : TrayMenu.Uncheck(k_MenuMouse)
}

ToggleMouse(*) {
    global Cfg
    Cfg["ShowMouse"] := !Cfg["ShowMouse"]
    SaveSettings()
    SyncTrayChecks()
    ; Turning ripples on while the keyboard is hidden has to wake the hooks, which
    ; JumpHooksToFront skips when everything is hidden.
    if Cfg["ShowMouse"]
        JumpHooksToFront()
}

OpenIniFile(*) {
    global IniPath
    SaveSettings()          ; flush first, or you'd edit a stale file
    try Run(IniPath)
    catch
        Run('notepad.exe "' . IniPath . '"')
}

; ==============================================================================
;  Settings panels -- both built from the spec, so neither can drift
; ==============================================================================
ShowSettings(kind) {
    global SettingSpec, Cfg, SettingsGui, SettingsHwnd, SettingsCtrls, SettingsPanelKind

    CloseSettings()
    SettingsCtrls := Map()
    SettingsPanelKind := kind

    title := (kind = "kb") ? "Keyboard Settings" : "Mouse Click Settings"
    g := Gui("+AlwaysOnTop -MaximizeBox", title)
    g.SetFont("s9", "Segoe UI")
    SettingsGui := g
    SettingsHwnd := g.Hwnd

    g.Add("Text", "xm w440", "Hover any control for what it does. Changes take effect when you "
                           . "press Save -- items marked * need a restart as well."
                           . ((kind = "mouse")
                              ? "`nColors here are shared with the keyboard's mouse block."
                              : ""))

    for sp in SettingSpec {
        if !InPanel(sp, kind)
            continue
        star := sp.live ? "" : " *"
        switch sp.type {
            case "int", "float":
                g.Add("Text", "xm y+6 w150 h22 +0x200", sp.label . star)
                sl := g.Add("Slider", "x+4 yp w200 h22 NoTicks Range" . sp.min . "-" . sp.max,
                            Round(Cfg[sp.key] * sp.scale))
                lb := g.Add("Text", "x+6 yp w70 h22 +0x200", FmtVal(Cfg[sp.key], sp.unit))
                sl.OnEvent("Change", SettingSlider.Bind(sp, lb))
                SettingsCtrls[sp.key] := sl
                TipCtl(sl, sp.tip)
            case "bool":
                ; sameRow continues the previous checkbox's line instead of starting a
                ; new one, so related switches read as one group. bw narrows them to fit.
                pos := (sp.HasProp("sameRow") && sp.sameRow) ? "x+10 yp" : "xm y+6"
                wid := sp.HasProp("bw") ? sp.bw : 440
                cb := g.Add("CheckBox", pos . " w" . wid . " Checked" (Cfg[sp.key] ? 1 : 0),
                            sp.label . star)
                SettingsCtrls[sp.key] := cb
                TipCtl(cb, sp.tip)
            case "color":
                g.Add("Text", "xm y+6 w150 h22 +0x200", sp.label . star)
                ed := g.Add("Edit", "x+4 yp w100", Format("{:06X}", Cfg[sp.key]))
                bt := g.Add("Button", "x+4 yp w60 h22", "Pick")
                bt.OnEvent("Click", PickSettingColor.Bind(sp, ed))
                SettingsCtrls[sp.key] := ed
                TipCtl(ed, sp.tip), TipCtl(bt, sp.tip)
            case "choice":
                g.Add("Text", "xm y+6 w150 h22 +0x200", sp.label . star)
                dd := g.Add("DropDownList", "x+4 yp w200", sp.choices)
                dd.Value := Cfg[sp.key]
                SettingsCtrls[sp.key] := dd
                TipCtl(dd, sp.tip)
            default:
                g.Add("Text", "xm y+6 w150 h22 +0x200", sp.label . star)
                ed := g.Add("Edit", "x+4 yp w200", Cfg[sp.key])
                SettingsCtrls[sp.key] := ed
                TipCtl(ed, sp.tip)
        }
    }

    other     := (kind = "kb") ? "mouse" : "kb"
    otherName := (kind = "kb") ? "Mouse Settings" : "Keyboard Settings"

    bSave := g.Add("Button", "xm y+14 w106", "Save")
    bDef  := g.Add("Button", "x+5 yp w106", "Restore defaults")
    bOther:= g.Add("Button", "x+5 yp w106", otherName)
    bCanc := g.Add("Button", "x+5 yp w106", "Cancel")
    bSave.OnEvent("Click", SaveSettingsPanel)
    bDef.OnEvent("Click", RestoreDefaults)
    ; Deferred by one tick: ShowSettings tears the current panel down, and doing that
    ; from inside a control's own event handler means destroying the window the
    ; handler is still running in. The negative timer lets this thread return first.
    bOther.OnEvent("Click", (*) => SetTimer(() => SwitchPanel(other), -1))
    bCanc.OnEvent("Click", CancelSettings)
    TipCtl(bSave, "Writes every value to the INI and applies what can be applied without "
                . "rebuilding the layout. If you changed anything marked *, you'll be offered "
                . "a restart.")
    TipCtl(bDef, "Resets the controls on THIS panel only. Nothing is written until you press Save.")
    TipCtl(bOther, "Switches straight over to the " . otherName . " panel. Anything you have "
                 . "changed here but not saved is discarded, so press Save first if you meant "
                 . "to keep it.")

    g.OnEvent("Close", CancelSettings)
    g.Show("AutoSize")
}

;---- The only place a settings panel is torn down. It has to be a named function:
; `SettingsGui := 0` inside a fat arrow assigns a LOCAL under v2's assume-local
; rule, so the old inline handlers destroyed the window and left the stale object
; behind -- which is what RippleSkipWindow then tripped over on the next click.
CloseSettings(*) {
    global SettingsGui, SettingsHwnd
    SettingsHwnd := 0
    if SettingsGui {
        try SettingsGui.Destroy()
        SettingsGui := 0
    }
}

;---- CtrlToolTip sets TTM_SETMAXTIPWIDTH to the full screen width, which switches
; OFF Windows' own word wrapping, so a long tip renders as one very long thin line.
; Insert the breaks ourselves and it becomes a readable block. Done at runtime so
; the spec's texts stay editable and the wrap column stays one number.
TipCtl(ctrl, text, col := 58) {
    global Cfg
    if !Cfg["ShowTips"]
        return
    out := "", line := ""
    for word in StrSplit(text, " ") {
        if (line != "" && StrLen(line) + StrLen(word) + 1 > col) {
            out .= (out = "" ? "" : "`n") . line
            line := word
        } else
            line := (line = "" ? word : line . " " . word)
    }
    if (line != "")
        out .= (out = "" ? "" : "`n") . line
    CtrlToolTip(ctrl, out)
}

FmtVal(v, unit) {
    return ((v = Round(v)) ? Round(v) : Format("{:.1f}", v)) . unit
}

SettingSlider(sp, lb, Ctrl, *) {
    ; v2's / always yields a Float, so an unscaled slider would turn a clean 312
    ; into 312.0 and leak that into the INI. Only divide when it's really fractional.
    v := (sp.scale = 1) ? Ctrl.Value : Ctrl.Value / sp.scale
    lb.Text := FmtVal(v, sp.unit)
}

PickSettingColor(sp, ed, *) {
    global SettingsGui, SuspendRipples
    ; The common dialog is its own window, so IgnorePanel wouldn't cover it and every
    ; click inside the picker would paint a ring across it.
    SuspendRipples := true
    cur := Integer("0x" . StrReplace(StrReplace(Trim(ed.Text), "0x"), "#"))
    res := ChooseColor(cur, SettingsGui.Hwnd)
    SuspendRipples := false
    if (res != "")
        ed.Text := Format("{:06X}", Integer(res))
}

RestoreDefaults(*) {
    global SettingSpec, SettingsCtrls, SettingsPanelKind
    for sp in SettingSpec {
        if (!InPanel(sp, SettingsPanelKind) || !SettingsCtrls.Has(sp.key))
            continue
        c := SettingsCtrls[sp.key]
        switch sp.type {
            case "int", "float", "choice": c.Value := (sp.type = "choice") ? sp.def
                                                    : Round(sp.def * sp.scale)
            case "bool":  c.Value := sp.def ? 1 : 0
            case "color": c.Text := Format("{:06X}", sp.def)
            default:      c.Text := sp.def
        }
    }
}

; Reads the OPEN panel's controls and returns only what differs from Cfg. Nothing
; in a panel touches Cfg until this runs -- sliders just move their own readout --
; which is why an un-committed panel switch used to lose edits silently.
PanelChanges() {
    global SettingSpec, Cfg, SettingsCtrls, SettingsPanelKind
    changes := Map()
    for sp in SettingSpec {
        if (!InPanel(sp, SettingsPanelKind) || !SettingsCtrls.Has(sp.key))
            continue
        c := SettingsCtrls[sp.key]
        switch sp.type {
            case "int":    v := c.Value
            case "float":  v := c.Value / sp.scale
            case "choice": v := c.Value
            case "bool":   v := c.Value ? true : false
            case "color":  v := Integer("0x" . StrReplace(StrReplace(Trim(c.Text), "0x"), "#"))
            default:       v := c.Text
        }
        if (Cfg[sp.key] != v)
            changes[sp.key] := v
    }
    return changes
}

;---- Fold the open panel's edits into Cfg, raising the restart flag for any that
; are baked into the layout. Does not touch the INI; the caller decides that.
CommitPanel() {
    global Cfg, PendingRestart
    for key, v in PanelChanges() {
        Cfg[key] := v
        sp := SpecFor(key)
        if (sp && !sp.live)
            PendingRestart := true
    }
}

;---- MsgBox with rings suppressed, owned by whatever window it belongs to, and
; genuinely modal over a settings panel.
;
; Two separate problems being solved. A bare MsgBox is not topmost, so against an
; AlwaysOnTop settings panel it opened UNDERNEATH and looked like nothing happened;
; Owner fixes that, because an owned window is always kept above its owner. And
; ownership alone doesn't stop you clicking the panel behind it, so the panel is
; disabled for the duration -- otherwise you could edit controls whose values the
; pending answer is about to act on.
;
; The rings are suppressed because the dialog is its own window, which IgnorePanel
; wouldn't catch.
AskUser(text, opts) {
    global SuspendRipples, SettingsHwnd, SettingsGui, MyGui
    SuspendRipples := true
    opts .= " Owner" . (SettingsHwnd ? SettingsHwnd : MyGui.Hwnd)
    if SettingsHwnd
        try SettingsGui.Opt("+Disabled")
    res := MsgBox(text, "InputEcho", opts)
    if SettingsHwnd
        try SettingsGui.Opt("-Disabled")
    SuspendRipples := false
    return res
}

MaybeRestart() {
    global PendingRestart
    if !PendingRestart
        return
    PendingRestart := false     ; asked once; don't nag on every later close
    if (AskUser("Some changes need a restart to take effect.`n`nRestart now?", "YesNo Icon?") = "Yes")
        Reload()
}

SaveSettingsPanel(*) {
    CommitPanel()
    SaveSettings()
    ApplyLive()
    CloseSettings()
    MaybeRestart()
}

;---- Jump to the other panel. Offers to keep the current panel's edits first --
; silently dropping them was the old behaviour and it was indefensible. No restart
; prompt here: that waits until you're finished on the other panel, so one prompt
; covers changes made on both.
SwitchPanel(other) {
    if PanelChanges().Count {
        res := AskUser("Save your changes to this panel before switching?", "YesNoCancel Icon?")
        if (res = "Cancel")
            return
        if (res = "Yes") {
            CommitPanel()
            SaveSettings()
            ApplyLive()
        }
    }
    ShowSettings(other)
}

;---- Cancel / X. Discards this panel, but still settles any restart owed from a
; panel you already saved before switching.
CancelSettings(*) {
    CloseSettings()
    MaybeRestart()
}

; ==============================================================================
;  ChooseColor -- standard Windows color picker
;  Based on Teadrinker's code: autohotkey.com/boards/viewtopic.php?f=83&t=131364
;  Returns "0xRRGGBB", or "" if cancelled.
;
;  One change from the version we've carried around: the customColorsArr guard sat
;  INSIDE the `if !init` block, so on the second call with no array passed it stayed
;  an empty string and the write-back loop at the bottom threw. Moved it out.
; ==============================================================================
ChooseColor(initColor := 0, hWnd := 0, customColorsArr := '', flags := 3) {
    ; flags: CC_RGBINIT = 1, CC_FULLOPEN = 2, CC_PREVENTFULLOPEN = 4
    static init := false, customColors := '', CHOOSECOLOR := ''
         , RGB_BGR := color => (color & 0xFF) << 16 | color & 0xFF00 | color >> 16

    if !IsObject(customColorsArr)
        customColorsArr := []
    customColorsArr.Length := 16

    if !init {
        init := true
        customColors := Buffer(64)
        Loop 16 {
            clr := customColorsArr.Has(A_Index) && IsInteger(customColorsArr[A_Index])
                ? RGB_BGR(customColorsArr[A_Index] & 0xFFFFFF) : 0xFFFFFF
            NumPut('UInt', clr, customColors, (A_Index - 1) * 4)
        }
        CHOOSECOLOR := Buffer(A_PtrSize * 9)
        NumPut('Ptr', customColors.ptr, NumPut('Ptr', CHOOSECOLOR.size, CHOOSECOLOR) + A_PtrSize * 3)
    }
    NumPut('Ptr', hWnd, CHOOSECOLOR, A_PtrSize)
    NumPut('UInt', RGB_BGR(initColor), CHOOSECOLOR, A_PtrSize * 3)
    NumPut('UInt', flags, CHOOSECOLOR, A_PtrSize * 5)
    res := DllCall('Comdlg32\ChooseColor', 'Ptr', CHOOSECOLOR)
    Loop 16 {
        customColorsArr[A_Index] := RGB_BGR(NumGet(customColors, (A_Index - 1) * 4, 'UInt'))
    }
    if (res)
        return Format("0x{:06X}", RGB_BGR(NumGet(CHOOSECOLOR, A_PtrSize * 3, 'UInt')))
    return ""
}
