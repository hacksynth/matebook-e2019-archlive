ARM64 recovery tools
====================

7-Zip File Manager is the primary graphical file manager. It is a separate
open-source component; see 7-Zip\License.txt and 7-Zip\readme.txt.

Explorer++ is also included as an optional file manager, but the WinPE base
does not provide its Direct2D/DXGI dependencies by default.

Open Command Prompt.cmd opens a new command prompt.
Open PowerShell.cmd opens Windows PowerShell.
Open DiskPart.cmd opens the interactive disk partitioning tool.
Open Graphical File Manager.cmd starts 7-Zip File Manager.
diagnose.ps1 writes storage and driver diagnostics to
C:\RecoveryPE\pe-diagnostics.txt.
