#Requires AutoHotkey v2.0
#SingleInstance Force

; Путь к файлу настроек в той же папке, где и скрипт/exe
global INI_FILE := A_ScriptDir "\settings.ini"

; Идентификаторы языков (Language ID)
global ID_ENG := 0x0409
global ID_RUS := 0x0419
global ID_UKR := 0x0422

global LCTRL_LAYOUT := ID_RUS
global RCTRL_LAYOUT := ID_UKR

; Внутреннее состояние языка в памяти скрипта
global currentLayoutState := ID_ENG
global loggingEnabled := false
; Кэш проверки исключений для последнего активного приложения.
global lastActiveProcess := ""
global lastActiveProcessExcluded := false

; Последнее слово и введенные после него разделители.
global charBuffer := ""
global trailingSeparators := ""

; Переменные времени зажатия Ctrl
global leftCtrlTime := 0
global rightCtrlTime := 0

; Глобальные массивы для окон и элементов текста
global textGuis := []
global textControls := []
global borderGuis := []

; Инициализируем настройки из INI
InitSettings()

; --- ИНИЦИАЛИЗАЦИЯ ДИНАМИЧЕСКИХ ТЕКСТОВЫХ ИНДИКАТОРОВ ДЛЯ ВСЕХ МОНИТОРОВ ---
monitorCount := MonitorGetCount()
Loop monitorCount
{
    monitorIndex := A_Index
    if (BORDER_THICKNESS > 0) {
        for side in ["N", "E", "S", "W"] {
            if (!InStr(BORDER_SIDES, side))
                continue
            borderGui := Gui("+AlwaysOnTop -Caption -DPIScale +ToolWindow +E0x20 +E0x08000000")
            borderGui.MarginX := 0
            borderGui.MarginY := 0
            borderGuis.Push({hwnd: borderGui, monitor: monitorIndex, side: side})
        }
    }
    if (INDICATOR_FONT_SIZE = 0)
        continue
    guiWidth := Ceil(150 * INDICATOR_FONT_SIZE / 48)
    guiHeight := Ceil(100 * INDICATOR_FONT_SIZE / 48)

    ; ИСПРАВЛЕНО: Добавлен нативный флаг E0x00000008 (WS_EX_TOPMOST) для жесткой фиксации слоя поверх всех окон
    guiObj := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20 +E0x80000 +E0x00000008")
    guiObj.BackColor := "111111"
    WinSetTransColor("111111", guiObj)

    guiObj.SetFont("S" INDICATOR_FONT_SIZE " Bold", "Arial")
    txtCtrl := guiObj.AddText("X0 Y0 W" . guiWidth . " H" . guiHeight . " Center cWhite", "RU")

    textGuis.Push({hwnd: guiObj, w: guiWidth, h: guiHeight})
    textControls.Push(txtCtrl)

    guiObj.Show("Hide W" . guiWidth . " H" . guiHeight . " NoActivate")
}

; Первичный безопасный опрос языка при старте
UpdateStateFromSystem()

; Таймер проверки раскладки (200 мс)
SetTimer(SyncLanguages, 200)


; --- ИСКЛЮЧЕНИЕ ПРОГРАММ И ПЕРЕХВАТ КЛАВИШ ---
#HotIf not IsActiveProcessExcluded()

; --- ДИНАМИЧЕСКИЙ САМОЗАПУСКАЮЩИЙСЯ INPUTHOOK ---
global ih := InputHook("V I101 M B")
ih.KeyOpt("{Backspace}{Left}{Right}{Up}{Down}{Escape}{Delete}{Alt}{LWin}{RWin}", "N")
ih.OnChar := OnKeyPress
ih.OnKeyDown := OnSpecialKeyPress
ih.OnEnd := OnInputHookEnd
ih.Start()

OnInputHookEnd(ihObj) {
    try {
        ihObj.Start()
    }
}

; Сброс единого глобального буфера от мусора (ИСПРАВЛЕНО!)
OnSpecialKeyPress(ihObj, vk, sc) {
    ; Навигация и редактирование делают сохраненное слово недостоверным.
    ; Tab и Enter обрабатываются как разделители в OnKeyPress.
    if (vk = 0x08 || (vk >= 0x25 && vk <= 0x28) || vk = 0x1B || vk = 0x2E || vk = 0x12 || vk = 0x5B || vk = 0x5C) {
        global charBuffer, trailingSeparators
        charBuffer := ""
        trailingSeparators := ""
    }
}

; --- ТРАНСЛИТЕРАЦИЯ ВЫДЕЛЕННОГО ТЕКСТА ИЛИ ПОСЛЕДНЕГО СЛОВА ---
Pause::
{
    global currentLayoutState, ID_ENG, ID_RUS, charBuffer, trailingSeparators

    ; 1. Бережно сохраняем текущий буфер обмена пользователя
    oldClipboard := ClipboardAll()
    A_Clipboard := ""

    ; Копируем выделенный текст через Ctrl+C
    Send("^c")

    ; Выделение имеет приоритет; без выделения используем последнее слово.
    hasSelection := ClipWait(0.5)
    if (!hasSelection && charBuffer = "")
    {
        A_Clipboard := oldClipboard
        return
    }

    copiedText := hasSelection ? A_Clipboard : charBuffer
    LogMessage("Transliterate " . copiedText)

    ; Карты раскладок (строгий учет регистра символов)
    enChars := "qwertyuiop[]asdfghjkl;'zxcvbnm,.QWERTYUIOP{}ASDFGHJKL:`"ZXCVBNM<>``~@#$^&"
    ruChars := "йцукенгшщзхъфывапролджэячсмитьбюЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮёЁ`"№;:?"

    ; Общие символы раскладок преобразуются по текущему направлению.
    enPunctuation := Map(".", "ю", ",", "б", "?", ",", "/", ".", ";", "ж", ":", "Ж", "`"", "Э")
    ruPunctuation := Map(".", "/", ",", "?", "?", "&", ";", "$", ":", "^", "`"", "@")

    transliteratedText := ""
    isTextRussian := false
    ; Направление для неоднозначных символов определяется последней заменой.
    fromRussian := false

    ; Посимвольно перебираем и конвертируем строку
    Loop parse, copiedText
    {
        char := A_LoopField

        ; Неоднозначная пунктуация не меняет направление последующих замен.
        punctuation := fromRussian ? ruPunctuation : enPunctuation
        if (punctuation.Has(char))
        {
            transliteratedText .= punctuation[char]
            continue
        }

        posEn := InStr(enChars, char, true)
        if (posEn > 0)
        {
            ; Расстановка конкатенации строго через точки с пробелами по правилам v2
            transliteratedText .= SubStr(ruChars, posEn, 1)
            fromRussian := false
            continue
        }

        posRu := InStr(ruChars, char, true)
        if (posRu > 0)
        {
            transliteratedText .= SubStr(enChars, posRu, 1)
            fromRussian := true
            isTextRussian := true
            continue
        }

        transliteratedText .= char
    }
    LogMessage("Transliterated " . transliteratedText)

    if (hasSelection) {
        SendText(transliteratedText)
        trailingSeparators := ""
    } else {
        ; Удаляем слово вместе с разделителями, затем восстанавливаем их.
        backspaceCount := StrLen(charBuffer) + StrLen(trailingSeparators)
        SetKeyDelay(10, 15)
        SendEvent("{Backspace " backspaceCount "}")
        SendText(transliteratedText . trailingSeparators)
    }

    ; Перезаписываем глобальный буфер новым значением
    charBuffer := transliteratedText

    ; Вычисляем, на какой язык нужно перейти
    if (isTextRussian)
        currentLayoutState := ID_ENG
    else
        currentLayoutState := ID_RUS

    ; КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ (ПОРЯДОК ДЕЙСТВИЙ): Сначала принудительно ждем,
    ; пока пользователь ПОЛНОСТЬЮ ОТПУСТИТ все физические клавиши на клавиатуре!
    KeyWait("LCtrl")
    KeyWait("RCtrl")
    KeyWait("LShift")
    KeyWait("RShift")
    KeyWait("Backspace")

    ; Только теперь, на "чистой" от модификаторов клавиатуре, тихо меняем раскладку в фоне.
    ; У Windows больше нет ни единого аппаратного повода выкинуть оверлей смены языка!
    LogMessage("Switch language after transliteration to " . currentLayoutState)
    SwitchLanguageUniversal(currentLayoutState)

    ; Восстанавливаем исходный буфер обмена пользователя
    A_Clipboard := oldClipboard
}

; Фиксируем время нажатия Ctrl
~LCtrl::
{
    global leftCtrlTime
    if (!leftCtrlTime)
        leftCtrlTime := A_TickCount
}

~RCtrl::
{
    global rightCtrlTime
    if (!rightCtrlTime)
        rightCtrlTime := A_TickCount
}

; Обработка Левого Ctrl
~LCtrl Up::
{
    global leftCtrlTime, currentLayoutState
    duration := A_TickCount - leftCtrlTime
    leftCtrlTime := 0

    if (duration > 0 && duration < 300 && A_PriorKey = "LControl")
    {
        if (!IsNoSLProcess())
            UpdateStateFromSystem()
        currentLayoutState := (currentLayoutState = LCTRL_LAYOUT) ? ID_ENG : LCTRL_LAYOUT
        LogMessage("Switch language by LCtrlUp to " . currentLayoutState)
        SwitchLanguageUniversal(currentLayoutState)
    }
}

; Обработка Правого Ctrl
~RCtrl Up::
{
    global rightCtrlTime, currentLayoutState
    duration := A_TickCount - rightCtrlTime
    rightCtrlTime := 0

    if (duration > 0 && duration < 300 && A_PriorKey = "RControl")
    {
        if (!IsNoSLProcess())
            UpdateStateFromSystem()

        currentLayoutState := (currentLayoutState = RCTRL_LAYOUT) ? ID_ENG : RCTRL_LAYOUT
        LogMessage("Switch language by RCtrlUp to " . currentLayoutState)
        SwitchLanguageUniversal(currentLayoutState)
    }
}
#HotIf

; Переключение логирования доступно также в исключенных приложениях.
^!+l::
{
    global loggingEnabled, lastActiveProcess
    loggingEnabled := !loggingEnabled
    ToolTip(loggingEnabled ? "Logging..." : "")
    if (loggingEnabled) {
      lastActiveProcess := ""
      IsActiveProcessExcluded()
    }
}

; Переключение вывода звука
^!+s::
{
    global ENABLE_SOUND
    ENABLE_SOUND := !ENABLE_SOUND
}

LogMessage(text) {
    global loggingEnabled
    if (!loggingEnabled)
        return

    FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") " : " text "`n", "script.log")
}

; --- ФУНКЦИИ ---
IsLanguageInstalled(langId) {
    layoutCount := DllCall("GetKeyboardLayoutList", "Int", 0, "Ptr", 0, "Int")
    if (layoutCount <= 0)
        return false

    layouts := Buffer(layoutCount * A_PtrSize)
    layoutCount := DllCall("GetKeyboardLayoutList", "Int", layoutCount, "Ptr", layouts, "Int")

    Loop layoutCount {
        layout := NumGet(layouts, (A_Index - 1) * A_PtrSize, "Ptr")

        if ((layout & 0xFFFF) = langId)
            return true
    }

    return false
}

GetInputWindow()
{
    targetWin := WinExist("A")
    if (!targetWin)
        return 0

    threadId := DllCall("GetWindowThreadProcessId", "Ptr", targetWin, "Ptr", 0, "UInt")
    ; GUITHREADINFO: cbSize, flags, hwndActive, hwndFocus, ...
    guiInfo := Buffer(A_PtrSize = 8 ? 72 : 48, 0)
    NumPut("UInt", guiInfo.Size, guiInfo)
    if DllCall("GetGUIThreadInfo", "UInt", threadId, "Ptr", guiInfo, "Int") {
        focusWin := NumGet(guiInfo, 8 + A_PtrSize, "Ptr")
        if (focusWin)
            return focusWin
    }
    return targetWin
}

SwitchLanguageUniversal(targetLangId)
{
    targetWin := GetInputWindow()
    if targetWin
    {
        ; В lParam нужен HKL установленной раскладки, а не только LANGID.
        layoutCount := DllCall("GetKeyboardLayoutList", "Int", 0, "Ptr", 0, "Int")
        if (layoutCount <= 0)
            return
        layouts := Buffer(layoutCount * A_PtrSize)
        layoutCount := DllCall("GetKeyboardLayoutList", "Int", layoutCount, "Ptr", layouts, "Int")
        targetLayout := 0
        Loop layoutCount {
            layout := NumGet(layouts, (A_Index - 1) * A_PtrSize, "Ptr")
            if ((layout & 0xFFFF) = targetLangId) {
                targetLayout := layout
                break
            }
        }
        if (!targetLayout) {
            LogMessage("SwitchLanguageUniversal: layout not installed: " . targetLangId)
            return
        }

        ; Посылаем запрос окну ввода и ждем обработки, чтобы таймер не прочитал
        ; старую раскладку до обработки PostMessage. Зависшее приложение не блокирует скрипт.
        result := 0
        delivered := DllCall("SendMessageTimeoutW", "Ptr", targetWin, "UInt", 0x0050,
            "Ptr", 0, "Ptr", targetLayout, "UInt", 0x0002, "UInt", 200,
            "Ptr*", &result, "Ptr")
        LogMessage("SwitchLanguageUniversal: hwnd=" . targetWin . " HKL=" . targetLayout . " delivered=" . delivered)

        if (!IsNoSLProcess())
            UpdateStateFromSystem()
    }

    ; Обновляем текстовый индикатор (RU/UA) в углу экрана
    LogMessage("DrawLanguage from SwitchLanguageUniversal " . targetLangId)
    DrawLanguage(currentLayoutState)
}

UpdateStateFromSystem()
{
    global currentLayoutState
    try {
        targetWin := GetInputWindow()
        if targetWin {
            threadId := DllCall("GetWindowThreadProcessId", "Ptr", targetWin, "Ptr", 0)
            layoutId := DllCall("GetKeyboardLayout", "UInt", threadId, "Ptr")
            systemLang := layoutId & 0xFFFF
            if (systemLang != 0) {
                currentLayoutState := systemLang
                LogMessage("UpdateStateFromSystem. hwnd=" . targetWin . " thread=" . threadId . " HKL=" . layoutId . " currentLayoutState=" . currentLayoutState)
            }
        }
    }
}

SyncLanguages()
{
    global currentLayoutState, textGuis, borderGuis
    ; LogMessage("SyncLanguages.  currentLayoutState = " . currentLayoutState)

    if (!IsNoSLProcess())
        UpdateStateFromSystem()

    ; ИСПРАВЛЕНО: Каждые 200 мс принудительно возвращаем окна на самый верхний слой (TopMost),
    ; если они сейчас не спрятаны под экран (то есть мы не в исключении)
    if (!IsActiveProcessExcluded())
    {
        for g in textGuis
        {
            ; Этот вызов WinAPI возвращает окно на самый верх без мерцания и потери фокуса ввода
            DllCall("User32\SetWindowPos", "Ptr", g.hwnd.Hwnd, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0013)
        }
    }

    if (!IsActiveProcessExcluded()) {
        for g in borderGuis
            DllCall("User32\SetWindowPos", "Ptr", g.hwnd.Hwnd, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0013)
    }
    DrawLanguage(currentLayoutState)
}

IsNoSLProcess()
{
    global NoSLProcesses
    try {
        activeProcess := StrLower(WinGetProcessName("A"))
        for exeName in NoSLProcesses {
            if (activeProcess = exeName)
                return true
        }
    } catch {
        return false
    }
    return false
}

IsActiveProcessExcluded()
{
    global ExcludedProcesses, lastActiveProcess, lastActiveProcessExcluded
    try {
        activeProcess := StrLower(WinGetProcessName("A"))
            ; Быстрый выход, если тот же процесс
        if (activeProcess = lastActiveProcess)
            return lastActiveProcessExcluded

        LogMessage("ActiveProcess: " . activeProcess)
        isExcluded := (WinGetClass("A") = "TscShellContainerClass")
        if (!isExcluded) {
            for exeName in ExcludedProcesses {
                if (activeProcess = exeName) {
                    isExcluded := true
                    break
                }
            }
        }
        ; Кешируем
        lastActiveProcess := activeProcess
        lastActiveProcessExcluded := isExcluded
        return lastActiveProcessExcluded
    } catch {
        lastActiveProcess := ""
        lastActiveProcessExcluded := false
        return false
    }
}

; Метод OnKeyPress использует глобальный буфер (ИСПРАВЛЕНО!)
OnKeyPress(ihObj, char)
{
    ; InputHook может передать несколько символов за один вызов.
    Loop parse, char {
        PlayLetterSound(A_LoopField)
        OnTypedCharacter(A_LoopField)
    }
}

PlayLetterSound(char)
{
    global ENABLE_SOUND, currentLayoutState, ID_ENG, ID_RUS, ID_UKR
    global SOUND_ENG_KEY_FILE, SOUND_RUS_KEY_FILE, SOUND_UKR_KEY_FILE

    if (!ENABLE_SOUND || !RegExMatch(char, "i)^[a-zа-яёґєії]$") || IsActiveProcessExcluded())
        return

    ; Учитываем смену окна или раскладки до очередного опроса таймера.
    if (!IsNoSLProcess())
        UpdateStateFromSystem()

    soundFile := ""
    if (currentLayoutState = ID_ENG && RegExMatch(char, "i)^[a-z]$"))
        soundFile := SOUND_ENG_KEY_FILE
    else if (currentLayoutState = ID_RUS && RegExMatch(char, "i)^[а-яё]$"))
        soundFile := SOUND_RUS_KEY_FILE
    else if (currentLayoutState = ID_UKR && RegExMatch(char, "i)^[а-щьюяґєії]$"))
        soundFile := SOUND_UKR_KEY_FILE

    ; SND_FILENAME | SND_ASYNC | SND_NODEFAULT: не задерживаем ввод
    ; и не заменяем отсутствующий файл системным звуком.
    if (soundFile != "" && FileExist(soundFile))
        DllCall("winmm\PlaySoundW", "Str", soundFile, "Ptr", 0, "UInt", 0x00020003)
}

OnTypedCharacter(char)
{
    global HotstringsObj, charBuffer, trailingSeparators

    if (InStr(" `t`r`n,.!?-()", char))
    {
        ; Подстановка выполняется только на первом разделителе после слова.
        if (trailingSeparators = "")
        for abbreviation, replacement in HotstringsObj
        {
            if (StrLower(charBuffer) = StrLower(abbreviation))
            {
                backspaceCount := StrLen(charBuffer) + 1
                SetKeyDelay(10, 15)
                SendEvent("{Backspace " backspaceCount "}")

                remainingText := replacement
                while (remainingText != "")
                {
                    rPos := InStr(remainingText, "\r")
                    nPos := InStr(remainingText, "\n")

                    if (rPos = 0 && nPos = 0) {
                        SendText(remainingText)
                        break
                    }

                    if (rPos != 0 && (nPos = 0 || rPos < nPos)) {
                        chunk := SubStr(remainingText, 1, rPos - 1)
                        if (chunk != "")
                            SendText(chunk)

                        Send("+{Enter}")
                        remainingText := SubStr(remainingText, rPos + 2)
                    } else {
                        chunk := SubStr(remainingText, 1, nPos - 1)
                        if (chunk != "")
                            SendText(chunk)

                        Send("{Enter}")
                        remainingText := SubStr(remainingText, nPos + 2)
                    }
                }

                SendText(char)
                ; Запоминаем реально вставленное слово, включая многострочные подстановки.
                charBuffer := ""
                trailingSeparators := ""
                replacementText := StrReplace(StrReplace(replacement, "\r", "`n"), "\n", "`n")
                Loop parse, replacementText
                    RememberCharacter(A_LoopField)
                break
            }
        }
        RememberCharacter(char)
        return
    }
    RememberCharacter(char)
}

RememberCharacter(char)
{
    global charBuffer, trailingSeparators
    if (InStr(" `t`r`n,.!?-()", char)) {
        if (charBuffer != "")
            trailingSeparators .= char
        return
    }
    ; Пунктуация внутри слова может быть буквой в неверной раскладке (cgfcb,j).
    ; Окончательную границу слова задают пробел, Tab или перевод строки.
    if (trailingSeparators != "") {
        if (InStr(trailingSeparators, " ") || InStr(trailingSeparators, "`t")
            || InStr(trailingSeparators, "`r") || InStr(trailingSeparators, "`n"))
            charBuffer := ""
        else
            charBuffer .= trailingSeparators
        trailingSeparators := ""
    }
    charBuffer .= char
}

HideLanguages()
{
    global textGuis, borderGuis
    for g in textGuis
    {
        g.hwnd.Hide()
    }
    for g in borderGuis
        g.hwnd.Hide()
}

DrawBorders(hexColor)
{
    global borderGuis, BORDER_THICKNESS
    for g in borderGuis {
        try MonitorGet(g.monitor, &left, &top, &right, &bottom)
        catch {
            g.hwnd.Hide()
            continue
        }
        width := right - left
        height := bottom - top
        thickness := Min(BORDER_THICKNESS, width, height)
        switch g.side {
            case "N": x := left, y := top, w := width, h := thickness
            case "E": x := right - thickness, y := top, w := thickness, h := height
            case "S": x := left, y := bottom - thickness, w := width, h := thickness
            case "W": x := left, y := top, w := thickness, h := height
        }
        g.hwnd.BackColor := hexColor
        g.hwnd.Show("NoActivate X" x " Y" y " W" w " H" h)
    }
}

DrawLanguage(langId)
{
    static lastLang := 0
    static lastWasExcluded := false
    global textGuis, textControls, SOUND_ENG_FILE, SOUND_RUS_FILE, SOUND_UKR_FILE

    if (langId != lastLang) {
        LogMessage("Switch language from " . lastLang . " to " . langId)
    }

    color := 0
    labelText := ""

    if (langId = ID_RUS) {
        color := COLOR_RUS
        labelText := "RU"
    } else if (langId = ID_UKR) {
        color := COLOR_UKR
        labelText := "UA"
    } else if (langId = ID_ENG) {
        color := COLOR_ENG
        labelText := "EN"
    }

    currentExcluded := IsActiveProcessExcluded()

    if (langId = lastLang && currentExcluded = lastWasExcluded)
        return

    if (ENABLE_SOUND && langId != lastLang)
    {
        flags := 0x00020001
        if (langId = ID_ENG && SOUND_ENG_FILE != "")
            soundFile := SOUND_ENG_FILE
        else if (langId = ID_RUS && SOUND_RUS_FILE != "")
            soundFile := SOUND_RUS_FILE
        else if (langId = ID_UKR && SOUND_UKR_FILE != "")
            soundFile := SOUND_UKR_FILE

        if (soundFile != "" && FileExist(soundFile))
            DllCall("winmm\PlaySoundW", "Str", soundFile, "Ptr", 0, "UInt", 0x00020003)
    }

    lastLang := langId
    lastWasExcluded := currentExcluded

    if (color = 0 || currentExcluded)
    {
        HideLanguages()
        return
    }

    hexColor := Format("{:06X}", color & 0xFFFFFF)
    DrawBorders(hexColor)

    for index, g in textGuis
    {
        ; Обновляем координаты только при смене языка или состояния исключения.
        ; Если монитор отключен, скрываем его индикатор до следующего переключения.
        try MonitorGetWorkArea(index, &Left, &Top, &Right, &Bottom)
        catch {
            g.hwnd.Hide()
            continue
        }
        posX := Right - g.w - 20
        posY := Bottom - g.h - 10

        txtCtrl := textControls[index]
        txtCtrl.Value := labelText
        txtCtrl.Opt("c" hexColor)
        g.hwnd.Show("X" posX " Y" posY " NoActivate")
    }
}

GetAbsolutePath(path) {
    if (path = "") {
        return ""
    }
    
    if (FileExist(path)) {
        return path
    }
    return A_ScriptDir . "\" . path
}

InitSettings()
{
    global ENABLE_SOUND, COLOR_RUS, COLOR_UKR, COLOR_ENG, ExcludedProcesses, NoSLProcesses, HotstringsObj
    global SOUND_ENG_FILE, SOUND_RUS_FILE, SOUND_UKR_FILE
    global SOUND_ENG_KEY_FILE, SOUND_RUS_KEY_FILE, SOUND_UKR_KEY_FILE
    global INDICATOR_FONT_SIZE, BORDER_THICKNESS, BORDER_SIDES
    global LCTRL_LAYOUT, RCTRL_LAYOUT

    if not FileExist(INI_FILE)
    {
        IniWrite("true", INI_FILE, "General", "EnableSound")
        IniWrite("2", INI_FILE, "General", "IndicatorSize")
        IniWrite("3", INI_FILE, "General", "BorderThickness")
        IniWrite("NESW", INI_FILE, "General", "BorderSides")
        IniWrite("cs.exe, mstsc.exe", INI_FILE, "General", "ExcludeApps")
        IniWrite("teams.exe, m365copilot.exe", INI_FILE, "General", "NoSystemLayoutApps")
        IniWrite("0xDA291C", INI_FILE, "Colors", "Russian")
        IniWrite("0x0057B8", INI_FILE, "Colors", "Ukrainian")
        IniWrite("0", INI_FILE, "Colors", "English")

        IniWrite("Sounds\en.wav", INI_FILE, "Sounds", "EnglishSwitch")
        IniWrite("Sounds\ru.wav", INI_FILE, "Sounds", "RussianSwitch")
        IniWrite("Sounds\ua.wav", INI_FILE, "Sounds", "UkrainianSwitch")
        IniWrite("Sounds\en.wav", INI_FILE, "Sounds", "EnglishKey")
        IniWrite("Sounds\ru.wav", INI_FILE, "Sounds", "RussianKey")
        IniWrite("Sounds\ua.wav", INI_FILE, "Sounds", "UkrainianKey")

        IniWrite("OK", INI_FILE, "Hotstrings", "щл")
    }

    ENABLE_SOUND := (IniRead(INI_FILE, "General", "EnableSound", "true") = "true")

    ; Толщина в пикселях; 0 отключает рамку. Стороны: верх, право, низ, лево.
    BORDER_THICKNESS := Max(0, Integer(IniRead(INI_FILE, "General", "BorderThickness", "3")))
    BORDER_SIDES := StrUpper(IniRead(INI_FILE, "General", "BorderSides", "NESW"))

    ; Уровни размера индикатора: 0=выключен, 1=S36, 2=S48, 3=S72, 4=S100.
    switch IniRead(INI_FILE, "General", "IndicatorSize", "2") {
        case "0": INDICATOR_FONT_SIZE := 0
        case "1": INDICATOR_FONT_SIZE := 36
        case "3": INDICATOR_FONT_SIZE := 72
        case "4": INDICATOR_FONT_SIZE := 100
        default: INDICATOR_FONT_SIZE := 48
    }

    rawExcludes := IniRead(INI_FILE, "General", "ExcludeApps", "")
    ExcludedProcesses := []
    loop parse, rawExcludes, ","{
        trimmed := Trim(A_LoopField)
        if (trimmed != "")
            ExcludedProcesses.Push(StrLower(trimmed))
    }
    rawExcludes := IniRead(INI_FILE, "General", "NoSystemLayoutApps", "")

    NoSLProcesses := []
    loop parse, rawExcludes, ","{
        trimmed := Trim(A_LoopField)
        if (trimmed != "")
            NoSLProcesses.Push(StrLower(trimmed))
    }

    COLOR_RUS := Number(IniRead(INI_FILE, "Colors", "Russian", "0xDA291C"))
    COLOR_UKR := Number(IniRead(INI_FILE, "Colors", "Ukrainian", "0x0057B8"))
    COLOR_ENG := Number(IniRead(INI_FILE, "Colors", "English", "0"))
    SOUND_ENG_FILE := GetAbsolutePath(IniRead(INI_FILE, "Sounds", "EnglishSwitch", "Sounds\en.wav"))
    SOUND_RUS_FILE := GetAbsolutePath(IniRead(INI_FILE, "Sounds", "RussianSwitch", "Sounds\ru.wav"))
    SOUND_UKR_FILE := GetAbsolutePath(IniRead(INI_FILE, "Sounds", "UkrainianSwitch", "Sounds\ua.wav"))
    SOUND_ENG_KEY_FILE := GetAbsolutePath(IniRead(INI_FILE, "Sounds", "EnglishKey", "Sounds\en.wav"))
    SOUND_RUS_KEY_FILE := GetAbsolutePath(IniRead(INI_FILE, "Sounds", "RussianKey", "Sounds\ru.wav"))
    SOUND_UKR_KEY_FILE := GetAbsolutePath(IniRead(INI_FILE, "Sounds", "UkrainianKey", "Sounds\ua.wav"))
    HotstringsObj := Map()
    try {
        pairs := IniRead(INI_FILE, "Hotstrings")
        loop parse, pairs, "`n", "`r" {
            trimmedLine := Trim(A_LoopField)
            if (trimmedLine = "")
                continue
            splitPos := InStr(trimmedLine, "=")
            if splitPos {
                key := Trim(SubStr(trimmedLine, 1, splitPos - 1))
                val := Trim(SubStr(trimmedLine, splitPos + 1))
                HotstringsObj[key] := val
            }
        }
    }
    if (!IsLanguageInstalled(ID_RUS) && IsLanguageInstalled(ID_UKR))
        LCTRL_LAYOUT := ID_UKR
    if (!IsLanguageInstalled(ID_UKR) && IsLanguageInstalled(ID_RUS))
        RCTRL_LAYOUT := ID_RUS
}
