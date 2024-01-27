Attribute VB_Name = "perlInterface"

Public perl_pid As String

' colors (B,G,R)

Public Const color_black 		= 0
Public Const color_red 			= &H0000FF
Public Const color_green 		= &H00FF00
Public Const color_blue 		= &HFF0000
Public Const color_orange 		= &H0080FF

Public Const color_grey 		= &HAAAAAA

Public Const color_dark_red 	= &H000099
Public Const color_dark_green 	= &H009900
Public Const color_dark_blue 	= &H990000
Public Const color_dark_grey 	= &H777777

Public Const color_light_red 	= &HF9999F
Public Const color_light_green 	= &H99FF99
Public Const color_light_blue 	= &HFF9999
Public Const color_light_grey 	= &HCCCCCC


Sub perlEnd(result, Optional ByVal color_val As Integer)
    perlStatusMsg result, color_val
    perlInterfaceDialog.buttonCancel.Enabled = False
    ' perlInterfaceDialog.buttonRun.Enabled = True
    ' perlInterfaceDialog.enableCheckBoxes (True)
    ' perlInterfaceDialog.deleteExistingFiles.value = False
End Sub


Function perlStart(pid As String)
    ' if the window is not showing, the perl was run from the
    ' command line, so we open the window in the "running" state
    ' without knowing the parameters

    If Not perlInterfaceDialog.Visible Then
        initPerlInterface "started from perl(" + pid +")"
    End If

    perl_pid = pid
    Dim msg
    msg = "perlStart pid=" + pid
    perlStatusMsg msg
    perlInterfaceDialog.buttonCancel.Enabled = True
    perlStart = True
End Function



Sub perlProgressMsg(msg, Optional ByVal color_val As Integer)
    Dim the_color
    If (IsMissing(color_val)) Then color_val = color_purple
    perlInterfaceDialog.progressMsg.caption = msg
    perlInterfaceDialog.progressMsg.ForeColor = color_val
    perlDisplay msg, color_val
End Sub



Sub perlStatusMsg(msg, Optional ByVal color_val As Integer)
    Dim the_color
    If (IsMissing(color_val)) Then color_val = color_blue
    perlInterfaceDialog.statusMsg.caption = msg
    perlInterfaceDialog.statusMsg.ForeColor = color_val
End Sub


Sub perlDisplay(msg, Optional ByVal color_val As Integer)
    Dim the_html, height
    the_html = "<font color='#" + color_val.ToString("x6") + "'>" + msg + "</font><br>"
    Dim browser As WebBrowser_V1
    Set browser = perlInterfaceDialog.browser
    browser.Document.Write the_html
    height = browser.Document.Body.ScrollHeight
    browser.Document.parentWindow.Scroll 0, height
End Sub




Sub initPerlInterface(Optional msg)
    perl_pid = ""

    perlInterfaceDialog.statusMsg.caption = ""
    perlInterfaceDialog.progressMsg.caption = ""

    If Not IsMissing(msg) Then perlProgressMsg(msg)

    Dim the_style
    Dim browser As WebBrowser_V1
    Set browser = perlInterfaceDialog.browser
    browser.Navigate ("about:blank")
    the_style = "<style> body { font-family: arial, helvetica; font-size:14px } </style>"
    browser.Document.Write (the_style)

    perlDisplay "perlInterface started ...",color_red

    If Not perlProgressMsg.Visible Then
        perlProgressMsg.Show (vbModeless)
    End If
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
