Attribute VB_Name = "perlInterface"

Public perl_pid As String

' dont you just love the weird vba syntax, &H, and
' it can't have leading zeros, and if it is less than
' six digits it MUST have a trailing & or it gets intrepreted
' as a (negative) number in a 16 bit integer context

Public Const rgb_black As Long = 0
Public Const rgb_red As Long = &HFF0000
Public Const rgb_green As Long = &HFF00&
Public Const rgb_blue As Long = &HFF&
Public Const rgb_cyan As Long = &HFFFF&
Public Const rgb_magenta As Long = &HFF00FF
Public Const rgb_yellow As Long = &HFFFF00

Public start_count As Integer


Function intToHex6(long_color)
    Dim str
    str = Hex(long_color)
    While (Len(str) < 6)
        str = "0" + str
    Wend
    intToHex6 = str
End Function


Function rgbToBgr(rgb_color)
    Dim r, g, b As Long
    r = (rgb_color And &HFF0000) / &H10000
    g = rgb_color And &HFF00&
    b = (rgb_color And &HFF&) * &H10000
    rgbToBgr = b + g + r
End Function



Sub perlEnd(result, Optional ByVal color_val)
    perlStatusMsg result, color_val
    perlInterfaceDialog.cancelButton.Enabled = False
End Sub


Function perlStart(pid As String, Optional title)
    initPerlInterface "VBA perlStart(" + pid + ")"
    
    perl_pid = pid
    perlInterfaceDialog.cancelButton.Enabled = True
    If (Not IsMissing(title)) Then
        perlInterfaceDialog.Caption = title
    End If
    
    start_count = start_count + 1
    perlStart = start_count
End Function




Sub setTitle(title)
    perlInterfaceDialog.Caption = title
End Sub


Sub perlStatusMsg(msg, Optional rgb_color)
    If (IsMissing(rgb_color)) Then rgb_color = rgb_blue
    perlInterfaceDialog.statusMsg.Caption = msg ' + " hex_rgb_color(" + intToHex6(rgb_color) + ")"
    perlInterfaceDialog.statusMsg.ForeColor = rgbToBgr(rgb_color)
    perlDisplay "Status: " + msg, rgb_color
End Sub


Sub perlProgressMsg(msg, Optional rgb_color As Long)
    If (IsMissing(rgb_color)) Then rgb_color = rgb_cyan
    perlInterfaceDialog.progressMsg.Caption = msg   ' + " hex_rgb_color(" + intToHex6(rgb_color) + ")"
    perlInterfaceDialog.progressMsg.ForeColor = rgbToBgr(rgb_color)
    perlDisplay "Progress: " + msg, rgb_color
End Sub


Sub perlDisplay(msg, Optional rgb_color)
    Dim the_html, height
    If (IsMissing(rgb_color)) Then rgb_color = rgb_grey
    
    Dim hex_str
    hex_str = intToHex6(rgb_color)
    the_html = "<font color='#" + hex_str + "'>" + msg + "</font><br>" + vbNewLine
    ' the_html = "<font color='#" + hex_str + "'>" + msg + " hex_rgb_color(" + intToHex6(rgb_color) + ")</font><br>" + vbNewLine
    
    Dim browser ' As WebBrowser_V1
    Set browser = perlInterfaceDialog.browser
    browser.Document.Write the_html
    height = browser.Document.Body.ScrollHeight
    browser.Document.parentWindow.Scroll 0, height
End Sub




Sub initPerlInterface(Optional msg)

    perl_pid = ""

    perlInterfaceDialog.Caption = "Perl Interface"
    perlInterfaceDialog.statusMsg.Caption = ""
    perlInterfaceDialog.progressMsg.Caption = ""

    Dim the_style
    Dim browser '  As WebBrowser_V1
    Set browser = perlInterfaceDialog.browser
    
    browser.Navigate ("about:blank")
    the_style = "<style> body { font-family: arial, helvetica; font-size:12px } </style>"
    browser.Document.Write (the_style)

    If (Not IsMissing(msg)) Then
        perlProgressMsg msg
    End If
    
    perlDisplay "VBA initPerlInterface ...", rgb_blue
        
    If Not perlInterfaceDialog.visible Then
        perlInterfaceDialog.Show (vbModeless)
    End If
    
End Sub




Public Sub callPerlScript(script, Optional with_ui, Optional visible, Optional args)

    If (IsMissing(with_ui)) Then with_ui = False
    If (IsMissing(visible)) Then visible = False
    If (IsMissing(args)) Then args = ""
        
    Dim cmd
    cmd = "c:\perl\bin\perl.exe " + script + " " + args
    
    If (with_ui) Then
        initPerlInterface (cmd)
        perlStatusMsg "Starting ..."
        perlProgressMsg "calling " + cmd
    End If
    
    ' vbHide              0   Window is hidden and focus is passed to the hidden window.
    ' vbNormalFocus       1   Window has focus and is restored to its original size and position.
    ' vbMinimizedFocus    2   Window is displayed as an icon with focus.
    ' vbMaximizedFocus    3   Window is maximized with focus.
    ' vbNormalNoFocus     4   Window is restored to its most recent size and position. The currently active window remains active.
    ' vbMinimizedNoFocus  6   Window is displayed as an icon. The currently active window remains active.
    
    ' Dim my_focus
    ' my_focus = vbNormalFocus
    ' If getBankInfoWindow.hideWindow.Value Then my_focus = vbMinimizedFocus

    Dim how
    how = vbHide
    If (visible) Then how = vbNormalFocus
    
    Dim pid As String
    ' pid = Shell("C:\WINDOWS\NOTEPAD.EXE", 1)
    pid = Shell(cmd, how)
    If (with_ui) Then
        perlProgressMsg "script pid = " + pid
    End If
    
    ' my_focus
End Sub



 

' Sub openGetBankInfoWindow()
'
'     ' this code assumes that it is safe to start again
'     ' if the window is not showing ... i.e. the window
'     ' should make sure any dangling perl tasks are killed
'     ' if summarily closed.
'
'     If Not getBankInfoWindow.Visible Then
'         initGetBankWindow
'         ' getBankInfoWindow.deleteExistingFiles.value = False
'             ' gotta click it every time
'         getBankInfoWindow.buttonCancel.Enabled = False
'         getBankInfoWindow.buttonRun.Enabled = True
'         ' getBankInfoWindow.enableCheckBoxes True
'     End If
' End Sub
'
'
'
' Public Sub getBankInformation()
'     Dim args, script, cmd
'
'     'args = " "
'     'If getBankInfoWindow.deleteExistingFiles.value Then args = args + "INIT "
'     'If getBankInfoWindow.getSDCCU.value Then args = args + "SDCCU "
'     'If getBankInfoWindow.getWellsFargo.value Then args = args + "WF "
'     'If getBankInfoWindow.getBanistmo.value Then args = args + "BANISTMO "
'
'     initGetBankWindow "getBankInfo" ' + args
'     perlStateMsg "Starting ..."
'
'     script = "getBankInfo.pm XL" ' + args
'     cmd = "c:\perl\bin\perl.exe c:\dat\budget\getBank\" + script
'     ' cmd = "c:\perl\bin\prh_perl_IE11.exe c:\dat\budget\getBank\" + script
'
'     ' "Hide Window" checkbox doesn't really work.
'     ' 2nd Scripted::Application comes up regardless of vbHide
'     '
'     ' vbHide              0   Window is hidden and focus is passed to the hidden window.
'     ' vbNormalFocus       1   Window has focus and is restored to its original size and position.
'     ' vbMinimizedFocus    2   Window is displayed as an icon with focus.
'     ' vbMaximizedFocus    3   Window is maximized with focus.
'     ' vbNormalNoFocus     4   Window is restored to its most recent size and position. The currently active window remains active.
'     ' vbMinimizedNoFocus  6   Window is displayed as an icon. The currently active window remains active.
'
'     Dim my_focus
'     my_focus = vbNormalFocus
'     If getBankInfoWindow.hideWindow.value Then my_focus = vbMinimizedFocus
'
'     perlStatusMsg "calling getBankInfo.pm" + args
'     Shell cmd, my_focus
' End Sub
