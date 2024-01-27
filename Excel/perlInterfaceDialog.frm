VERSION 5.00
Begin {C62A69F0-16DC-11CE-9E98-00AA00574A4F} perlInterfaceDialog
   Caption         =   "Perl User Interface"
   ClientHeight    =   6870
   ClientLeft      =   120
   ClientTop       =   465
   ClientWidth     =   8880.001
   OleObjectBlob   =   "perlInterfaceDialog.frx":0000
   StartUpPosition =   1  'CenterOwner
End
Attribute VB_Name = "perlInterfaceDialog"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = False
Attribute VB_PredeclaredId = True
Attribute VB_Exposed = False


Private Sub cancelButton_Click()
   Dim cmd
   Dim msg
   buttonCancel.Enabled = False
   msg = "Killing Perl Process(" + perl_pid + ") ..."
   ' perlStateMsg msg, "orange"
   ' perlDisplay msg, "orange"
   cmd = "c:\perl\bin\perl.exe c:\base\Pub\Excel\" + "killPerlFromExcel.pm " + perl_pid
   Shell cmd, vbNormalFocus
   perl_pid = ""

   msg = "Cancelled by User"
   ' perlProgressMsg msg, "red"
   ' perlDisplay msg, "red"

End Sub
