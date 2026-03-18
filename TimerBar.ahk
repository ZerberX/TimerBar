; ============================================================
; TimerBar.ahk – AHK v2 Dual Countdown Bar (GDI+ Overlay)
; ============================================================
; Configuration – General
; ============================================================

TIMER_LONG     := 53          ; Long timer in seconds
TIMER_SHORT    := 36          ; Short timer in seconds
TRIGGER_KEY    := "4"         ; Trigger key (also passed through to the foreground app)
BAR_WIDTH      := 300         ; Bar width in pixels
BAR_HEIGHT     := 40          ; Bar height in pixels
UPDATE_MS      := 50          ; Update interval (ms)
BAR_OPACITY    := 200         ; Opacity (0 = invisible, 255 = fully opaque)
BORDER         := 4           ; Border width in pixels
BAR_OFFSET_X   := 0           ; Horizontal offset (positive = right, negative = left)
BAR_OFFSET_Y   := 90          ; Vertical offset (positive = down, negative = up)
MONITOR        := 2           ; Monitor index (ScrollLock shows indices)
BORDER_GROW    := 2.0         ; Border growth factor during red phase (1.0 = off, 2.0 = double, 3.0 = triple)
RED_PHASE      := 0.5         ; Red phase starts at this fraction of the action window (0.0–1.0, e.g. 0.3 = earlier, 0.7 = later)
TIME_FORMAT    := "MM:SS"     ; Time display: "MM:SS", "MM:SS.ms", "SS", "SS.ms", or "" (hidden)

; ============================================================
; Configuration – Colors (0xRRGGBB)
; ============================================================

CLR_BAR_BG       := 0x16213e  ; Bar background (empty area)
CLR_BORDER       := 0x1a1a2e  ; Border color (normal state)
CLR_BORDER_ALERT := 0xFF0000  ; Border color at full alert intensity
CLR_LONG_GREEN   := 0x00b894  ; Long timer: while short timer is running
CLR_LONG_YELLOW  := 0xfdcb6e  ; Long timer: first half of action window
CLR_LONG_RED     := 0xe94560  ; Long timer: second half of action window
CLR_SHORT        := 0x0984e3  ; Short timer
CLR_TEXT         := 0xffffff  ; Time display

; ============================================================
; Computed values
; ============================================================

global BORDER_MAX   := (BORDER_GROW > 1.0) ? Round(BORDER * BORDER_GROW) : BORDER
global GUI_W        := BAR_WIDTH  + (BORDER_MAX * 2)
global GUI_H        := BAR_HEIGHT + (BORDER_MAX * 2)
global INSET        := 3
global totalMsLong  := TIMER_LONG  * 1000
global totalMsShort := TIMER_SHORT * 1000

; Convert colors to ARGB (prepend alpha 0xFF)
global ARGB_BAR_BG       := 0xFF000000 | CLR_BAR_BG
global ARGB_BORDER       := 0xFF000000 | CLR_BORDER
global ARGB_LONG_GREEN   := 0xFF000000 | CLR_LONG_GREEN
global ARGB_LONG_YELLOW  := 0xFF000000 | CLR_LONG_YELLOW
global ARGB_LONG_RED     := 0xFF000000 | CLR_LONG_RED
global ARGB_SHORT        := 0xFF000000 | CLR_SHORT
global ARGB_TEXT         := 0xFF000000 | CLR_TEXT

; Decompose alert color into R/G/B for interpolation
global ALERT_R  := (CLR_BORDER_ALERT >> 16) & 0xFF
global ALERT_G  := (CLR_BORDER_ALERT >> 8)  & 0xFF
global ALERT_B  :=  CLR_BORDER_ALERT        & 0xFF
global BORDER_R := (CLR_BORDER >> 16) & 0xFF
global BORDER_G := (CLR_BORDER >> 8)  & 0xFF
global BORDER_B :=  CLR_BORDER        & 0xFF

; ============================================================
; Initialize GDI+
; ============================================================

DllCall("LoadLibrary", "Str", "gdiplus")
si := Buffer(24, 0)
NumPut("UInt", 1, si)
global gdipToken := 0
DllCall("gdiplus\GdiplusStartup", "Ptr*", &gdipToken, "Ptr", si, "Ptr", 0)

; Font resources (created once, reused)
global pFontFamily := 0
global pFont       := 0
global pFormat     := 0
DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", "Consolas", "Ptr", 0, "Ptr*", &pFontFamily)
DllCall("gdiplus\GdipCreateFont", "Ptr", pFontFamily, "Float", 16.0, "Int", 1, "Int", 2, "Ptr*", &pFont)
DllCall("gdiplus\GdipCreateStringFormat", "Int", 0, "Int", 0, "Ptr*", &pFormat)
DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", pFormat, "Int", 1)
DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", pFormat, "Int", 1)

; Large font for monitor index display
global pFontBig := 0
DllCall("gdiplus\GdipCreateFont", "Ptr", pFontFamily, "Float", 72.0, "Int", 1, "Int", 2, "Ptr*", &pFontBig)

; Persistent render resources
global hdcScreen  := 0
global hdcMem     := 0
global hBitmap    := 0
global hOldBmp    := 0
global blendBuf   := Buffer(4, 0)
global ptSrc      := Buffer(8, 0)
global ptDst      := Buffer(8, 0)
global szBuf      := Buffer(8, 0)

; ============================================================
; State
; ============================================================

global timerGui      := ""
global startTick     := 0
global timerRunning  := false
global guiPosX       := 0
global guiPosY       := 0
global indexGuis     := []
global indexShowing   := false

; ============================================================
; Hotkeys
; ============================================================

Hotkey "~" TRIGGER_KEY, OnTrigger
Hotkey "ScrollLock", ShowMonitorIndex

; ============================================================
; Get monitor bounds by index
; ============================================================

GetMonitorBounds(monIdx, &mx, &my, &mw, &mh) {
    count := MonitorGetCount()
    if monIdx < 1 || monIdx > count
        monIdx := 1
    MonitorGet(monIdx, &left, &top, &right, &bottom)
    mx := left
    my := top
    mw := right - left
    mh := bottom - top
}

; ============================================================
; ScrollLock: Show monitor indices on all screens
; ============================================================

ShowMonitorIndex(ThisHotkey) {
    global indexGuis, indexShowing, pFontBig, pFormat

    ; If already showing, close overlays
    if indexShowing {
        for g in indexGuis
            try g.Destroy()
        indexGuis := []
        indexShowing := false
        return
    }

    count := MonitorGetCount()
    indexGuis := []
    overlayW := 200
    overlayH := 200

    Loop count {
        idx := A_Index
        MonitorGet(idx, &left, &top, &right, &bottom)
        mw := right - left
        mh := bottom - top

        g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x80000 +E0x20")
        g.Show("x0 y0 w" overlayW " h" overlayH " NoActivate Hide")

        posX := left + (mw - overlayW) // 2
        posY := top  + (mh - overlayH) // 2

        DllCall("SetWindowPos", "Ptr", g.Hwnd
            , "Ptr", -1, "Int", posX, "Int", posY
            , "Int", overlayW, "Int", overlayH, "UInt", 0x0010)
        DllCall("ShowWindow", "Ptr", g.Hwnd, "Int", 8)

        hScr := DllCall("GetDC", "Ptr", 0, "Ptr")
        hMem := DllCall("CreateCompatibleDC", "Ptr", hScr, "Ptr")

        bi := Buffer(40, 0)
        NumPut("UInt", 40, bi, 0)
        NumPut("Int", overlayW, bi, 4)
        NumPut("Int", -overlayH, bi, 8)
        NumPut("UShort", 1, bi, 12)
        NumPut("UShort", 32, bi, 14)
        pBits := 0
        hBmp := DllCall("CreateDIBSection"
            , "Ptr", hMem, "Ptr", bi, "UInt", 0
            , "Ptr*", &pBits, "Ptr", 0, "UInt", 0, "Ptr")
        hOld := DllCall("SelectObject", "Ptr", hMem, "Ptr", hBmp, "Ptr")

        pG := 0
        DllCall("gdiplus\GdipCreateFromHDC", "Ptr", hMem, "Ptr*", &pG)
        DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", pG, "Int", 5)
        DllCall("gdiplus\GdipGraphicsClear", "Ptr", pG, "UInt", 0x00000000)

        ; Semi-transparent dark background
        GdipFillRect(pG, 0, 0, overlayW, overlayH, 0xCC1a1a2e)

        ; Large index number
        pBrushW := 0
        DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0xFFffffff, "Ptr*", &pBrushW)
        rc := Buffer(16, 0)
        NumPut("Float", 0.0, rc, 0)
        NumPut("Float", 10.0, rc, 4)
        NumPut("Float", Float(overlayW), rc, 8)
        NumPut("Float", Float(overlayH - 20), rc, 12)
        DllCall("gdiplus\GdipDrawString", "Ptr", pG, "WStr", String(idx), "Int", -1
            , "Ptr", pFontBig, "Ptr", rc, "Ptr", pFormat, "Ptr", pBrushW)
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBrushW)

        ; Small label below
        pBrushG := 0
        DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0xFFaaaaaa, "Ptr*", &pBrushG)
        rc2 := Buffer(16, 0)
        NumPut("Float", 0.0, rc2, 0)
        NumPut("Float", Float(overlayH - 50), rc2, 4)
        NumPut("Float", Float(overlayW), rc2, 8)
        NumPut("Float", 40.0, rc2, 12)
        labelText := "Monitor " idx
        DllCall("gdiplus\GdipDrawString", "Ptr", pG, "WStr", labelText, "Int", -1
            , "Ptr", pFont, "Ptr", rc2, "Ptr", pFormat, "Ptr", pBrushG)
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBrushG)

        DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pG)

        ; Blit to screen via UpdateLayeredWindow
        ptS := Buffer(8, 0)
        ptD := Buffer(8, 0)
        NumPut("Int", posX, ptD, 0)
        NumPut("Int", posY, ptD, 4)
        sz := Buffer(8, 0)
        NumPut("Int", overlayW, sz, 0)
        NumPut("Int", overlayH, sz, 4)
        bl := Buffer(4, 0)
        NumPut("UChar", 0, bl, 0)
        NumPut("UChar", 0, bl, 1)
        NumPut("UChar", 230, bl, 2)
        NumPut("UChar", 1, bl, 3)

        DllCall("UpdateLayeredWindow"
            , "Ptr", g.Hwnd, "Ptr", hScr
            , "Ptr", ptD, "Ptr", sz
            , "Ptr", hMem, "Ptr", ptS
            , "UInt", 0, "Ptr", bl, "UInt", 2)

        ; Clean up DC resources
        DllCall("SelectObject", "Ptr", hMem, "Ptr", hOld)
        DllCall("DeleteObject", "Ptr", hBmp)
        DllCall("DeleteDC", "Ptr", hMem)
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", hScr)

        indexGuis.Push(g)
    }

    indexShowing := true
    ; Auto-hide after 3 seconds
    SetTimer(HideMonitorIndex, -3000)
}

HideMonitorIndex() {
    global indexGuis, indexShowing
    for g in indexGuis
        try g.Destroy()
    indexGuis := []
    indexShowing := false
}

; ============================================================
; Key pressed → start timer
; ============================================================

OnTrigger(ThisHotkey) {
    global timerGui, startTick, timerRunning, guiPosX, guiPosY
    global hdcScreen, hdcMem, hBitmap, hOldBmp
    global blendBuf, ptSrc, ptDst, szBuf

    ; If a timer is already running, restart
    if timerRunning {
        SetTimer(UpdateBar, 0)
        FreeRenderResources()
        try timerGui.Destroy()
        timerRunning := false
    }

    ; Layered window + click-through
    timerGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x80000 +E0x20")
    timerGui.Show("x0 y0 w" GUI_W " h" GUI_H " NoActivate Hide")

    ; Position on configured monitor
    mx := 0, my := 0, mw := 0, mh := 0
    GetMonitorBounds(MONITOR, &mx, &my, &mw, &mh)
    guiPosX := mx + ((mw - GUI_W) // 2) + BAR_OFFSET_X
    guiPosY := my + ((mh - GUI_H) // 2) + BAR_OFFSET_Y

    DllCall("SetWindowPos", "Ptr", timerGui.Hwnd
        , "Ptr", -1, "Int", guiPosX, "Int", guiPosY
        , "Int", GUI_W, "Int", GUI_H, "UInt", 0x0010)
    DllCall("ShowWindow", "Ptr", timerGui.Hwnd, "Int", 8)

    ; Create persistent render resources
    hdcScreen := DllCall("GetDC", "Ptr", 0, "Ptr")
    hdcMem    := DllCall("CreateCompatibleDC", "Ptr", hdcScreen, "Ptr")

    bi := Buffer(40, 0)
    NumPut("UInt",   40,     bi, 0)
    NumPut("Int",    GUI_W,  bi, 4)
    NumPut("Int",   -GUI_H,  bi, 8)
    NumPut("UShort", 1,      bi, 12)
    NumPut("UShort", 32,     bi, 14)
    pBits := 0
    hBitmap := DllCall("CreateDIBSection"
        , "Ptr", hdcMem, "Ptr", bi, "UInt", 0
        , "Ptr*", &pBits, "Ptr", 0, "UInt", 0, "Ptr")
    hOldBmp := DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hBitmap, "Ptr")

    ; Pre-fill static structs
    NumPut("Int", 0, ptSrc, 0)
    NumPut("Int", 0, ptSrc, 4)
    NumPut("Int", guiPosX, ptDst, 0)
    NumPut("Int", guiPosY, ptDst, 4)
    NumPut("Int", GUI_W, szBuf, 0)
    NumPut("Int", GUI_H, szBuf, 4)
    NumPut("UChar", 0,           blendBuf, 0)
    NumPut("UChar", 0,           blendBuf, 1)
    NumPut("UChar", BAR_OPACITY, blendBuf, 2)
    NumPut("UChar", 1,           blendBuf, 3)

    ; Start
    startTick    := A_TickCount
    timerRunning := true

    ; Draw first frame immediately
    DrawFrame(totalMsLong, totalMsShort, 0)
    SetTimer(UpdateBar, UPDATE_MS)
}

; ============================================================
; Release render resources
; ============================================================

FreeRenderResources() {
    global hdcScreen, hdcMem, hBitmap, hOldBmp
    if hdcMem {
        DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hOldBmp)
        DllCall("DeleteObject", "Ptr", hBitmap)
        DllCall("DeleteDC",     "Ptr", hdcMem)
        hdcMem := 0
    }
    if hdcScreen {
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcScreen)
        hdcScreen := 0
    }
}

; ============================================================
; Timer update
; ============================================================

UpdateBar() {
    global startTick, timerRunning, timerGui, totalMsLong, totalMsShort

    if !timerRunning
        return

    elapsed     := A_TickCount - startTick
    remainLong  := totalMsLong  - elapsed
    remainShort := totalMsShort - elapsed

    ; Long timer expired → close everything
    if remainLong <= 0 {
        SetTimer(UpdateBar, 0)
        timerRunning := false
        FreeRenderResources()
        try timerGui.Destroy()
        return
    }

    DrawFrame(remainLong, remainShort, elapsed)
}

; ============================================================
; Draw frame
; ============================================================

DrawFrame(remainLong, remainShort, elapsed) {
    global timerGui, GUI_W, GUI_H, BAR_WIDTH, BAR_HEIGHT
    global BORDER, BORDER_MAX, BORDER_GROW, RED_PHASE, INSET
    global totalMsLong, totalMsShort
    global hdcScreen, hdcMem, ptDst, szBuf, ptSrc, blendBuf
    global pFont, pFormat
    global ARGB_BAR_BG, ARGB_BORDER, ARGB_LONG_GREEN, ARGB_LONG_YELLOW, ARGB_LONG_RED
    global ARGB_SHORT, ARGB_TEXT
    global ALERT_R, ALERT_G, ALERT_B, BORDER_R, BORDER_G, BORDER_B

    pG := 0
    DllCall("gdiplus\GdipCreateFromHDC", "Ptr", hdcMem, "Ptr*", &pG)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", pG, "Int", 0)
    DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", pG, "Int", 5)
    DllCall("gdiplus\GdipGraphicsClear", "Ptr", pG, "UInt", 0x00000000)

    ; ══════════════════════════════════════════════════════════
    ; Determine phase, border color and border thickness
    ; ══════════════════════════════════════════════════════════

    curBorder := BORDER
    actionWindow := totalMsLong - totalMsShort

    if remainShort <= 0 {
        elapsedInWindow := elapsed - totalMsShort
        intensity       := elapsedInWindow / actionWindow
        if intensity > 1.0
            intensity := 1.0

        ; Interpolate border color from normal to alert
        rr := BORDER_R + Round(intensity * (ALERT_R - BORDER_R))
        gg := BORDER_G + Round(intensity * (ALERT_G - BORDER_G))
        bb := BORDER_B + Round(intensity * (ALERT_B - BORDER_B))
        rr := Min(Max(rr, 0), 255)
        gg := Min(Max(gg, 0), 255)
        bb := Min(Max(bb, 0), 255)
        borderArgb := 0xFF000000 | (rr << 16) | (gg << 8) | bb

        ; Red phase: border growth
        if elapsedInWindow >= (actionWindow * RED_PHASE) {
            if BORDER_GROW > 1.0 {
                ; Progress within the red phase: 0.0 → 1.0
                redStart     := actionWindow * RED_PHASE
                redElapsed   := elapsedInWindow - redStart
                redDuration  := actionWindow - redStart
                growProgress := redElapsed / redDuration
                if growProgress > 1.0
                    growProgress := 1.0
                curBorder := BORDER + Round(growProgress * (BORDER_MAX - BORDER))
            }
        }
    } else {
        borderArgb := ARGB_BORDER
    }

    ; ══════════════════════════════════════════════════════════
    ; Draw – bar is always centered at (BORDER_MAX, BORDER_MAX)
    ; Border grows outward from the bar edge
    ; ══════════════════════════════════════════════════════════

    ; 1) Border (filled rectangle around the bar)
    bx := BORDER_MAX - curBorder
    by := BORDER_MAX - curBorder
    bw := BAR_WIDTH  + (curBorder * 2)
    bh := BAR_HEIGHT + (curBorder * 2)
    GdipFillRect(pG, bx, by, bw, bh, borderArgb)

    ; 2) Bar background
    GdipFillRect(pG, BORDER_MAX, BORDER_MAX, BAR_WIDTH, BAR_HEIGHT, ARGB_BAR_BG)

    ; 3) Long timer fill
    ratioLong := remainLong / totalMsLong
    fillWLong := Round(BAR_WIDTH * ratioLong)
    if remainShort > 0
        clrLong := ARGB_LONG_GREEN
    else {
        elapsedInWindow := elapsed - totalMsShort
        if elapsedInWindow < (actionWindow * RED_PHASE)
            clrLong := ARGB_LONG_YELLOW
        else
            clrLong := ARGB_LONG_RED
    }
    if fillWLong > 0
        GdipFillRect(pG, BORDER_MAX, BORDER_MAX, fillWLong, BAR_HEIGHT, clrLong)

    ; 4) Short timer (shrinks in width)
    if remainShort > 0 {
        ratioShort := remainShort / totalMsShort
        shortFullW := BAR_WIDTH - (INSET * 2)
        fillWShort := Round(shortFullW * ratioShort)
        if fillWShort > 0
            GdipFillRect(pG, BORDER_MAX + INSET, BORDER_MAX + INSET
                , fillWShort, BAR_HEIGHT - (INSET * 2), ARGB_SHORT)
    }

    ; 5) Time display
    if TIME_FORMAT != "" {
        timeStr := FormatSec(remainLong)
        GdipDrawText(pG, timeStr, BORDER_MAX, BORDER_MAX, BAR_WIDTH, BAR_HEIGHT, ARGB_TEXT)
    }

    ; Release graphics (bitmap + DC stay alive)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pG)

    ; Atomic blit to screen
    DllCall("UpdateLayeredWindow"
        , "Ptr",  timerGui.Hwnd
        , "Ptr",  hdcScreen
        , "Ptr",  ptDst
        , "Ptr",  szBuf
        , "Ptr",  hdcMem
        , "Ptr",  ptSrc
        , "UInt", 0
        , "Ptr",  blendBuf
        , "UInt", 2)
}

; ============================================================
; GDI+ helper: fill rectangle
; ============================================================

GdipFillRect(pG, x, y, w, h, argb) {
    pBrush := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &pBrush)
    DllCall("gdiplus\GdipFillRectangle", "Ptr", pG, "Ptr", pBrush
        , "Float", Float(x), "Float", Float(y), "Float", Float(w), "Float", Float(h))
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBrush)
}

; ============================================================
; GDI+ helper: draw centered text
; ============================================================

GdipDrawText(pG, text, x, y, w, h, argb) {
    global pFont, pFormat
    pBrush := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &pBrush)
    rc := Buffer(16, 0)
    NumPut("Float", Float(x), rc, 0)
    NumPut("Float", Float(y), rc, 4)
    NumPut("Float", Float(w), rc, 8)
    NumPut("Float", Float(h), rc, 12)
    DllCall("gdiplus\GdipDrawString", "Ptr", pG, "WStr", text, "Int", -1
        , "Ptr", pFont, "Ptr", rc, "Ptr", pFormat, "Ptr", pBrush)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBrush)
}

; ============================================================
; Helper: seconds → "MM:SS"
; ============================================================

FormatSec(remainMs) {
    global TIME_FORMAT
    if TIME_FORMAT = "SS" {
        return String(Ceil(remainMs / 1000))
    }
    if TIME_FORMAT = "SS.ms" {
        tenths := Ceil(remainMs / 100)
        s := tenths // 10
        t := Mod(tenths, 10)
        return Format("{}.{}", s, t)
    }
    if TIME_FORMAT = "MM:SS.ms" {
        tenths := Ceil(remainMs / 100)
        totalSec := tenths // 10
        t := Mod(tenths, 10)
        m := totalSec // 60
        s := Mod(totalSec, 60)
        return Format("{:02d}:{:02d}.{}", m, s, t)
    }
    ; Default: "MM:SS"
    sec := Ceil(remainMs / 1000)
    m := sec // 60
    s := Mod(sec, 60)
    return Format("{:02d}:{:02d}", m, s)
}
