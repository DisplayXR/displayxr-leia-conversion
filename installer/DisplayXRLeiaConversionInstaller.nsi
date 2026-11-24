; DisplayXR Leia Conversion Provider Installer Script
; Copyright 2026, Leia Inc.
; SPDX-License-Identifier: Apache-2.0
;
; Ships DisplayXR-LeiaConversion.dll (runtime ADR-053) and registers it at
; HKLM\Software\DisplayXR\ConversionProviders\leia-conversion (64-bit view):
; ProbeOrder 50, Supersedes dp-lift, Version written LAST. The runtime's
; conversion host (displayxr-conversion-host.exe) is the only process that maps
; the DLL, so the files are replaced under the discovery spec's §3.8 sequence:
; the maintenance mutex Global\DisplayXR-ConvMaintenance-leia-conversion, a
; Restart Manager session over the provider's files only (it closes the host,
; never the service), and nothing is started afterwards.
;
; Order-independent, no prerequisite:
;  - No DisplayXR runtime yet: files and row are written anyway; the row is the
;    runtime's public discovery contract and the runtime reads it once it is
;    installed. A runtime older than MIN_RUNTIME_VERSION has no conversion
;    providers and ignores the row; the installer says so and continues.
;  - No NeurD runtime yet: the provider loads without it and reports ABSENT
;    until NeurD's own installer has run. NeurD (its files, licence and models)
;    is never installed, downloaded or modified here.
;
; Handover from the Leia SR plug-in installer. Leia SR plug-in releases up to
; the one that dropped the provider installed this DLL into THEIR directory and
; wrote this same registry row with THEIR uninstaller in UninstallString. This
; installer takes the row over: it closes the host for the previous Binary
; wherever it is, rewrites every value to this package, and removes the
; superseded copy of the DLL from the other directory. See docs/installer.md.

;--------------------------------
; Build-time definitions (passed from CMake):
;   VERSION, VERSION_MAJOR, VERSION_MINOR, VERSION_PATCH, BUILD_NUM
;   BIN_DIR             — _package/bin/ (the DLL is in BIN_DIR/plugins/, the
;                         Restart Manager helper in BIN_DIR/tools/)
;   SOURCE_DIR          — repo root (icon, LICENSE)
;   OUTPUT_DIR          — where the installer .exe is written
;   MIN_RUNTIME_VERSION — first runtime with conversion providers (a notice only)
;   ALLOWLIST_NSH       — generated provenance-allowlist macros (optional)
;   SIGN_CMD            — signing command (optional; empty = unsigned)

!ifndef VERSION
	!define VERSION "0.1.0"
!endif
!ifndef VERSION_MAJOR
	!define VERSION_MAJOR "0"
!endif
!ifndef VERSION_MINOR
	!define VERSION_MINOR "1"
!endif
!ifndef VERSION_PATCH
	!define VERSION_PATCH "0"
!endif
!ifndef BUILD_NUM
	!define BUILD_NUM "0"
!endif
!ifndef MIN_RUNTIME_VERSION
	!define MIN_RUNTIME_VERSION ""
!endif

;--------------------------------
; Code signing (SIGN_CMD passed from CMake; empty = unsigned build). No secret
; lives here. The installer .exe is signed via !finalize; the UNINSTALLER via a
; two-pass build (compile an INNER installer whose only job is to emit the
; uninstaller to %TEMP%, run it, sign that file, File-include it in the real
; pass) because !uninstfinalize leaves a dangling certificate table on a small
; uninstaller. Same recipe as the DisplayXR runtime and the Leia SR plug-in.
!ifndef INNER
	!ifdef SIGN_CMD
		!if "${SIGN_CMD}" != ""
			!finalize '${SIGN_CMD} "%1"'
			!makensis '-DINNER "-DVERSION=${VERSION}" "-DVERSION_MAJOR=${VERSION_MAJOR}" "-DVERSION_MINOR=${VERSION_MINOR}" "-DVERSION_PATCH=${VERSION_PATCH}" "-DBUILD_NUM=${BUILD_NUM}" "-DSOURCE_DIR=${SOURCE_DIR}" "-DBIN_DIR=${BIN_DIR}" "-DMIN_RUNTIME_VERSION=${MIN_RUNTIME_VERSION}" "${__FILE__}"' = 0
			; .onInit writes %TEMP%\LeiaConversion_Uninstall.exe then Quit (exit 2).
			!system '"$%TEMP%\DisplayXRLeiaConversion_inner.exe"' = 2
			!system '${SIGN_CMD} "$%TEMP%\LeiaConversion_Uninstall.exe"' = 0
			!define USE_PRESIGNED_UNINST
		!endif
	!endif
!endif

;--------------------------------
; General Attributes

Name "DisplayXR Leia Conversion ${VERSION}"
!ifdef INNER
	OutFile "$%TEMP%\DisplayXRLeiaConversion_inner.exe"
	RequestExecutionLevel user
!else
	OutFile "${OUTPUT_DIR}\DisplayXRLeiaConversionSetup-${VERSION}.exe"
	RequestExecutionLevel admin
!endif
InstallDir "$PROGRAMFILES64\DisplayXR\Plugins\LeiaConversion"
InstallDirRegKey HKLM "Software\DisplayXR\Plugins\LeiaConversion" "InstallPath"
ShowInstDetails show
ShowUninstDetails show
; A silent install must never skip a locked file and exit 0: a held DLL aborts
; the install with a non-zero exit code and the row is never rewritten.
AllowSkipFiles off

!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "x64.nsh"
!include "LogicLib.nsh"
!include "WordFunc.nsh"
!insertmacro VersionCompare

; ADR-054 N4b: the runtime's provenance gate enforces by default — a provider
; DLL must be Authenticode-signed or have its SHA-256 under
; HKLM\Software\DisplayXR\Trust\Allowlist. installer/gen_allowlist_nsh.cmake
; computes the row from the exact bytes packed; a hand-run makensis without the
; define writes nothing (a signed release needs no row).
!ifdef ALLOWLIST_NSH
	!include "${ALLOWLIST_NSH}"
!else
	!macro DXR_ALLOWLIST_WRITE
	!macroend
	!macro DXR_ALLOWLIST_REMOVE
	!macroend
!endif

;--------------------------------
; Abort a pre-flight check without ever showing a modal in silent mode (NSIS
; does not suppress MessageBox under /S). Codes: 3 = not 64-bit. (2 is reserved:
; the INNER uninstaller-emitting pass exits 2 by design.)
!macro AbortWithReason CODE MSG
	${If} ${Silent}
		SetErrorLevel ${CODE}
	${Else}
		MessageBox MB_ICONSTOP "${MSG}" /SD IDOK
	${EndIf}
	Abort
!macroend

!define CONV_ID "leia-conversion"
!define CONV_DLL "DisplayXR-LeiaConversion.dll"
!define CONV_KEY "Software\DisplayXR\ConversionProviders\${CONV_ID}"
!define CONV_MUTEX "Global\DisplayXR-ConvMaintenance-${CONV_ID}"
!define PKG_KEY "Software\DisplayXR\Plugins\LeiaConversion"
!define ARP_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRLeiaConversion"

Var RmHelper      ; path of the dxr-rm-close.exe copy we run (in $PLUGINSDIR)
Var RmDir         ; RM session state dir
Var RmRc          ; closed.txt code: 0 closed, 10 nothing held, 1 RM failed, or timeout/noexec/nohelper/ended
Var RmLogLines    ; log.txt lines already DetailPrinted
Var ConvMutex     ; owned maintenance mutex handle ("" = not held)
Var PrevBinary    ; the row's Binary before this run ("" = no row)
Var LegacyBinary  ; PrevBinary when it is a copy of the DLL outside $INSTDIR ("" otherwise)

;--------------------------------
; Maintenance mutex + Restart Manager (discovery spec §3.8). Defined for the
; installer (PFX="") and the uninstaller (PFX="un.") — NSIS needs both copies.
;
;   1. create AND own the mutex, held to the end (the service spawns no host for
;      the provider while it is held);
;   2. a Restart Manager session over the provider's files only: it lists the
;      conversion host, which exits 20 ("closed for update"); the provider's
;      tasks report WARMING(updating), every app session and stream stays alive;
;   3. replace the files, write the row with Version LAST;
;   4. end the session WITHOUT restarting anything (the host never registers
;      for restart; the service respawns it on demand);
;   5. release the mutex.
; No taskkill fallback anywhere: nothing here may stop the service. The mutex is
; owned by the thread that created it, so it is taken and released from the
; same section (NSIS runs sections and their Calls on one thread).
!macro CONV_FUNCTIONS PFX

; First line of $0 (a marker file), CR/LF trimmed -> $1 ("" when unreadable).
Function ${PFX}RmReadCode
	StrCpy $1 ""
	ClearErrors
	FileOpen $2 "$0" r
	${IfNot} ${Errors}
		FileRead $2 $1
		FileClose $2
	${EndIf}
	${Do}
		StrCpy $2 $1 1 -1
		${If} $2 == "$\r"
		${OrIf} $2 == "$\n"
			StrCpy $1 $1 -1
		${Else}
			${ExitDo}
		${EndIf}
	${Loop}
FunctionEnd

; DetailPrint the helper's log.txt lines not printed yet.
Function ${PFX}RmPrintLog
	ClearErrors
	FileOpen $2 "$RmDir\log.txt" r
	${If} ${Errors}
		Return
	${EndIf}
	StrCpy $3 0
	${Do}
		ClearErrors
		FileRead $2 $1
		${If} ${Errors}
			${ExitDo}
		${EndIf}
		IntOp $3 $3 + 1
		${If} $3 > $RmLogLines
			${Do}
				StrCpy $4 $1 1 -1
				${If} $4 == "$\r"
				${OrIf} $4 == "$\n"
					StrCpy $1 $1 -1
				${Else}
					${ExitDo}
				${EndIf}
			${Loop}
			DetailPrint "  [rm] $1"
		${EndIf}
	${Loop}
	FileClose $2
	StrCpy $RmLogLines $3
FunctionEnd

; Wait up to $0 ms for file $1. Sets the error flag on timeout.
Function ${PFX}RmWaitFile
	StrCpy $2 0
	ClearErrors
	${Do}
		${If} ${FileExists} "$1"
			Return
		${EndIf}
		${If} $2 >= $0
			SetErrors
			Return
		${EndIf}
		Sleep 200
		IntOp $2 $2 + 200
	${Loop}
FunctionEnd

; Step 1. ERROR_ALREADY_EXISTS (183) means another installer (NeurD's own, or an
; older Leia SR plug-in installer) holds it: wait for it.
Function ${PFX}ConvMaintenanceTake
	StrCpy $ConvMutex ""
	System::Call 'kernel32::CreateMutexW(p 0, i 1, w "${CONV_MUTEX}") p.r0 ?e'
	Pop $1
	${If} $0 == 0
		DetailPrint "Could not create the conversion maintenance mutex (error $1) - continuing without it."
		Return
	${EndIf}
	${If} $1 == 183
		DetailPrint "Another installer is updating the conversion provider; waiting..."
		System::Call 'kernel32::WaitForSingleObject(p r0, i 120000) i.r2'
		; 0 = acquired, 0x80 = abandoned by its owner (acquired too)
		${If} $2 != 0
		${AndIf} $2 != 128
			DetailPrint "The conversion maintenance mutex is still held after 120 s - continuing without it."
			System::Call 'kernel32::CloseHandle(p r0)'
			Return
		${EndIf}
	${EndIf}
	StrCpy $ConvMutex $0
	DetailPrint "Holding ${CONV_MUTEX}."
FunctionEnd

; Step 5.
Function ${PFX}ConvMaintenanceRelease
	${If} $ConvMutex != ""
		System::Call 'kernel32::ReleaseMutex(p $ConvMutex)'
		System::Call 'kernel32::CloseHandle(p $ConvMutex)'
		StrCpy $ConvMutex ""
		DetailPrint "Released ${CONV_MUTEX}."
	${EndIf}
FunctionEnd

; Step 2: Restart Manager over the provider's files: the copy in $INSTDIR and,
; when the row pointed somewhere else, that file too ($LegacyBinary). One
; conversion host maps whichever of them was registered.
Function ${PFX}ConvRmClose
	StrCpy $RmLogLines 0
	StrCpy $RmDir "$PLUGINSDIR\rmconv"
	${IfNot} ${FileExists} "$RmHelper"
		StrCpy $RmRc "nohelper"
		DetailPrint "Restart Manager helper missing: a file still held will abort."
		Return
	${EndIf}
	RMDir /r "$RmDir"
	CreateDirectory "$RmDir"
	DetailPrint "Releasing the conversion provider's files (Restart Manager)..."
	ClearErrors
	${If} $LegacyBinary != ""
		ExecShell "open" '"$RmHelper"' 'session "$RmDir" "$INSTDIR\${CONV_DLL}" "$LegacyBinary"' SW_HIDE
	${Else}
		ExecShell "open" '"$RmHelper"' 'session "$RmDir" "$INSTDIR\${CONV_DLL}"' SW_HIDE
	${EndIf}
	${If} ${Errors}
		StrCpy $RmRc "noexec"
		Return
	${EndIf}
	StrCpy $0 120000
	StrCpy $1 "$RmDir\closed.txt"
	Call ${PFX}RmWaitFile
	${If} ${Errors}
		StrCpy $RmRc "timeout"
	${Else}
		StrCpy $0 "$RmDir\closed.txt"
		Call ${PFX}RmReadCode
		StrCpy $RmRc $1
	${EndIf}
	Call ${PFX}RmPrintLog
	${If} $RmRc == "0"
		DetailPrint "Restart Manager closed the conversion host (it exits 'closed for update')."
	${ElseIf} $RmRc == "10"
		DetailPrint "No process holds the conversion provider's files."
	${Else}
		DetailPrint "Restart Manager did not release the conversion provider's files ($RmRc)."
	${EndIf}
FunctionEnd

; Step 4: end the session; restart NOTHING.
Function ${PFX}ConvRmEnd
	${If} $RmRc == "0"
	${OrIf} $RmRc == "1"
	${OrIf} $RmRc == "timeout"
		FileOpen $2 "$RmDir\go.txt" w
		FileWrite $2 "end$\r$\n"
		FileClose $2
		StrCpy $0 60000
		StrCpy $1 "$RmDir\done.txt"
		Call ${PFX}RmWaitFile
		Call ${PFX}RmPrintLog
	${EndIf}
	StrCpy $RmRc "ended"
FunctionEnd

!macroend

!insertmacro CONV_FUNCTIONS ""
!insertmacro CONV_FUNCTIONS "un."

; Delete FILE; when it is still mapped, remove it at the next reboot rather
; than silently leaving it behind.
!macro DeleteHeld FILE
	ClearErrors
	Delete "${FILE}"
	${If} ${Errors}
		Delete /REBOOTOK "${FILE}"
		DetailPrint "${FILE} is still in use; it will be removed at the next reboot."
	${EndIf}
!macroend

;--------------------------------
; Interface Settings

!define MUI_ABORTWARNING
!define MUI_ICON "${SOURCE_DIR}\assets\displayxr_white.ico"
!define MUI_UNICON "${SOURCE_DIR}\assets\displayxr_white.ico"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${SOURCE_DIR}\LICENSE"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

;--------------------------------
; Installer Sections

Section "Leia Conversion Provider"
	SectionIn RO

	; NSIS is 32-bit: without this the row would land under WOW6432Node, which
	; the runtime (64-bit view) never reads.
	SetRegView 64

	; '/NOSTART' (a bundle passes it to every child installer) needs no handling:
	; NSIS ignores unknown switches and this installer never starts anything.

	; --- What is on the box (informational: nothing here is a prerequisite) ---
	ReadRegStr $0 HKLM "Software\DisplayXR\Runtime" "InstallPath"
	ReadRegStr $1 HKLM "Software\DisplayXR\Runtime" "Version"
	${If} $0 == ""
		DetailPrint "DisplayXR runtime not installed yet: the provider will be used once the runtime is installed."
	${Else}
		DetailPrint "DisplayXR runtime $1 found at $0"
		!if "${MIN_RUNTIME_VERSION}" != ""
			; $R1: 0 = equal, 1 = installed newer, 2 = floor newer (too old).
			${VersionCompare} "$1" "${MIN_RUNTIME_VERSION}" $R1
			${If} $1 != ""
			${AndIf} $R1 == 2
				DetailPrint "NOTE: DisplayXR runtime $1 has no conversion providers (they start with ${MIN_RUNTIME_VERSION}); it will ignore this one until it is updated."
			${EndIf}
		!endif
	${EndIf}
	; NeurD's own installer writes HKLM\SOFTWARE\LeiaInc\NeurD (default value =
	; its directory, "Version"). The provider also looks on PATH and NEURD_PATH,
	; so a missing key is a note, never a failure.
	ReadRegStr $2 HKLM "SOFTWARE\LeiaInc\NeurD" ""
	ReadRegStr $3 HKLM "SOFTWARE\LeiaInc\NeurD" "Version"
	${If} $2 == ""
		DetailPrint "The Leia conversion runtime is not registered on this PC: the provider reports ABSENT until it is installed (its own installer; not part of this package)."
	${Else}
		DetailPrint "Leia conversion runtime $3 registered at $2"
	${EndIf}

	; --- Whose row is it now? ---
	; A row whose Binary is a copy of the DLL outside $INSTDIR was written by a
	; Leia SR plug-in installer that still bundled the provider. This run takes
	; the row over; that copy is closed with ours and removed below.
	StrCpy $LegacyBinary ""
	ReadRegStr $PrevBinary HKLM "${CONV_KEY}" "Binary"
	${If} $PrevBinary != ""
	${AndIf} $PrevBinary != "$INSTDIR\${CONV_DLL}"
		${GetFileName} "$PrevBinary" $4
		${If} $4 == "${CONV_DLL}"
			StrCpy $LegacyBinary $PrevBinary
			DetailPrint "Taking over the ${CONV_ID} registration from $PrevBinary"
		${Else}
			DetailPrint "The ${CONV_ID} registration pointed at $PrevBinary (not removed); it now points at this package."
		${EndIf}
	${EndIf}

	InitPluginsDir
	File "/oname=$PLUGINSDIR\dxr-rm-close.exe" "${BIN_DIR}\tools\dxr-rm-close.exe"
	StrCpy $RmHelper "$PLUGINSDIR\dxr-rm-close.exe"

	Call ConvMaintenanceTake
	Call ConvRmClose

	SetOutPath "$INSTDIR"
	File "${BIN_DIR}\plugins\${CONV_DLL}"
	; The Restart Manager helper, next to Uninstall.exe: the uninstaller needs
	; it to release the DLL before deleting it.
	File "${BIN_DIR}\tools\dxr-rm-close.exe"

	; ADR-054 N4b: the digest of the DLL just written, so the enforcing
	; provenance gate admits it even when this build is unsigned.
	!insertmacro DXR_ALLOWLIST_WRITE

	; -----------------------------------------------------------------
	; HKLM\Software\DisplayXR\ConversionProviders\leia-conversion
	; (runtime docs/specs/runtime/conversion-provider-discovery.md §3.1).
	; ProbeOrder 50 = the vendor band. Supersedes = dp-lift hides the
	; runtime's legacy adapter over a display plug-in's lift slots (Leia SR
	; plug-ins that still fill them), so the two are never listed twice; it
	; never affects selection among other providers, so an absent NeurD
	; still falls through. Hosting is left to the runtime default
	; (satellite). A Settings subkey the user created survives. Version is
	; written LAST: it is the "row complete" marker the runtime re-describes
	; on, so it is removed first and rewritten after everything else.
	; -----------------------------------------------------------------
	DeleteRegValue HKLM "${CONV_KEY}" "Version"
	WriteRegStr   HKLM "${CONV_KEY}" "Binary"          "$INSTDIR\${CONV_DLL}"
	WriteRegStr   HKLM "${CONV_KEY}" "DisplayName"     "Leia conversion"
	WriteRegStr   HKLM "${CONV_KEY}" "Vendor"          "Leia Inc."
	WriteRegStr   HKLM "${CONV_KEY}" "UninstallString" "$\"$INSTDIR\Uninstall.exe$\""
	WriteRegStr   HKLM "${CONV_KEY}" "Supersedes"      "dp-lift"
	WriteRegDWORD HKLM "${CONV_KEY}" "ProbeOrder"      50
	WriteRegStr   HKLM "${CONV_KEY}" "Version"         "${VERSION}"

	; The superseded copy in the Leia SR plug-in's directory: unregistered now,
	; and no longer mapped (the session above closed its host).
	${If} $LegacyBinary != ""
		!insertmacro DeleteHeld "$LegacyBinary"
		DetailPrint "Removed the superseded copy $LegacyBinary"
	${EndIf}

	WriteRegStr HKLM "${PKG_KEY}" "InstallPath" "$INSTDIR"
	WriteRegStr HKLM "${PKG_KEY}" "Version"     "${VERSION}"

!ifdef USE_PRESIGNED_UNINST
	File "/oname=Uninstall.exe" "$%TEMP%\LeiaConversion_Uninstall.exe"
!else
	WriteUninstaller "$INSTDIR\Uninstall.exe"
!endif

	WriteRegStr HKLM "${ARP_KEY}" "DisplayName" "DisplayXR Leia Conversion Provider"
	WriteRegStr HKLM "${ARP_KEY}" "UninstallString" "$\"$INSTDIR\Uninstall.exe$\""
	WriteRegStr HKLM "${ARP_KEY}" "QuietUninstallString" "$\"$INSTDIR\Uninstall.exe$\" /S"
	WriteRegStr HKLM "${ARP_KEY}" "InstallLocation" "$INSTDIR"
	WriteRegStr HKLM "${ARP_KEY}" "DisplayIcon" "$INSTDIR\${CONV_DLL}"
	WriteRegStr HKLM "${ARP_KEY}" "Publisher" "Leia Inc."
	WriteRegStr HKLM "${ARP_KEY}" "DisplayVersion" "${VERSION}"
	WriteRegDWORD HKLM "${ARP_KEY}" "VersionMajor" ${VERSION_MAJOR}
	WriteRegDWORD HKLM "${ARP_KEY}" "VersionMinor" ${VERSION_MINOR}
	WriteRegDWORD HKLM "${ARP_KEY}" "NoModify" 1
	WriteRegDWORD HKLM "${ARP_KEY}" "NoRepair" 1
	${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
	IntFmt $0 "0x%08X" $0
	WriteRegDWORD HKLM "${ARP_KEY}" "EstimatedSize" "$0"

	; The session ends restarting nothing; then the mutex goes, and the service
	; respawns the conversion host on demand.
	Call ConvRmEnd
	Call ConvMaintenanceRelease

SectionEnd

; An aborted install (a file still locked) must not leave the helper waiting or
; the mutex held.
Function .onInstFailed
	Call ConvRmEnd
	Call ConvMaintenanceRelease
FunctionEnd

;--------------------------------
; Uninstaller

Section "Uninstall"
	SetRegView 64

	InitPluginsDir
	StrCpy $RmHelper "$PLUGINSDIR\dxr-rm-close.exe"
	CopyFiles /SILENT "$INSTDIR\dxr-rm-close.exe" "$PLUGINSDIR"
	StrCpy $LegacyBinary ""

	Call un.ConvMaintenanceTake

	; The row first, so the runtime's tasks fall through to the next provider at
	; the next create — but ONLY when it is still ours. A row whose Binary is
	; somewhere else belongs to whoever wrote it last and is left alone.
	ReadRegStr $PrevBinary HKLM "${CONV_KEY}" "Binary"
	${If} $PrevBinary == "$INSTDIR\${CONV_DLL}"
		DeleteRegKey HKLM "${CONV_KEY}"
		DeleteRegKey /ifempty HKLM "Software\DisplayXR\ConversionProviders"
	${ElseIf} $PrevBinary != ""
		DetailPrint "The ${CONV_ID} registration points at $PrevBinary, not at this package: left in place."
	${EndIf}
	; ADR-054 N4b: drop only the allowlist row this installer wrote.
	!insertmacro DXR_ALLOWLIST_REMOVE

	Call un.ConvRmClose

	!insertmacro DeleteHeld "$INSTDIR\${CONV_DLL}"
	Delete "$INSTDIR\dxr-rm-close.exe"
	Delete "$INSTDIR\Uninstall.exe"

	Call un.ConvRmEnd
	Call un.ConvMaintenanceRelease

	RMDir /REBOOTOK "$INSTDIR"
	; Shared with the other DisplayXR plug-ins: removed only when empty.
	RMDir "$PROGRAMFILES64\DisplayXR\Plugins"

	DeleteRegKey HKLM "${PKG_KEY}"
	DeleteRegKey HKLM "${ARP_KEY}"
	DeleteRegKey /ifempty HKLM "Software\DisplayXR\Plugins"

SectionEnd

Function un.onUninstFailed
	Call un.ConvRmEnd
	Call un.ConvMaintenanceRelease
FunctionEnd

;--------------------------------
; Installer Functions

Function .onInit
!ifdef INNER
	; Inner pass only: emit the uninstaller to %TEMP% (the binary that gets
	; signed and File-included by the real pass) then bail — no UI, no install.
	SetSilent silent
	WriteUninstaller "$%TEMP%\LeiaConversion_Uninstall.exe"
	Quit
!endif
	${IfNot} ${RunningX64}
		!insertmacro AbortWithReason 3 "DisplayXR Leia Conversion requires 64-bit Windows."
	${EndIf}
FunctionEnd

;--------------------------------
; Version Information

VIProductVersion "${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH}.0"
VIAddVersionKey "ProductName" "DisplayXR Leia Conversion Provider"
VIAddVersionKey "CompanyName" "Leia Inc."
VIAddVersionKey "LegalCopyright" "Copyright (c) 2026 Leia Inc."
VIAddVersionKey "FileDescription" "DisplayXR Leia Conversion Provider Installer"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
