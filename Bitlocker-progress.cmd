@echo off
setlocal enabledelayedexpansion
title BitLocker Encryption Monitor

:: 	 			           BitLocker Encryption Monitor V0.5
:: 	---------------------------------------------------------------------
::
::  - Refreshes encryption progress every 30 seconds
::  - Detects stalls (no progress change for 5+ minutes)
::  - Automatically pauses and resumes encryption on stall
::  - Alerts user when encryption is complete
::

:: ----------------------------------------------------------------
::  Administrator Privilege Check and elevation
:: ----------------------------------------------------------------
if not "%1"=="am_admin" (powershell start -verb runas '%0' am_admin & exit /b)

:: ----------------------------------------------------------------
::  Configuration  ^<-- Change DRIVE if monitoring a different volume
:: ----------------------------------------------------------------
set "DRIVE=C:"
set "REFRESH_SEC=30"
set "MAX_STALL=10"
::  Stall threshold = MAX_STALL x REFRESH_SEC = 10 x 30s = 300s (5 min)

:: ----------------------------------------------------------------
::  Internal Tracking Variables
:: ----------------------------------------------------------------
set "STALL_COUNT=0"
set "LAST_PERCENT=INIT"
set "RESUME_COUNT=0"
set "TMPFILE=%TEMP%\bl_monitor_%RANDOM%.tmp"


:: ================================================================
::  MAIN MONITORING LOOP
:: ================================================================
:LOOP
cls
echo  ================================================================
echo    BITLOCKER ENCRYPTION MONITOR  --  Drive: %DRIVE%
echo    %date%  ^|  %time%
echo  ================================================================

:: ----------------------------------------------------------------
::  Capture BitLocker Status (single call per cycle)
:: ----------------------------------------------------------------
set "CURRENT_PERCENT=N/A"
set "CONV_STATUS=N/A"

manage-bde -status %DRIVE% >"%TMPFILE%" 2>&1

for /f "tokens=3" %%P in (
    'findstr /i "Percentage Encrypted" "%TMPFILE%"'
) do set "CURRENT_PERCENT=%%P"

for /f "tokens=3,4" %%A in (
    'findstr /i "Conversion Status" "%TMPFILE%"'
) do set "CONV_STATUS=%%A %%B"

:: ----------------------------------------------------------------
::  Display Current Status
:: ----------------------------------------------------------------
echo.
echo    Percentage Encrypted  :  !CURRENT_PERCENT!
echo    Conversion Status     :  !CONV_STATUS!
echo    Stall Counter         :  !STALL_COUNT! of %MAX_STALL%  ^(threshold = 5 min^)
if !RESUME_COUNT! gtr 0 (
    echo    Auto-Recoveries Done  :  !RESUME_COUNT!
)
echo.

:: ----------------------------------------------------------------
::  Handle Unavailable / Error Status
:: ----------------------------------------------------------------
if "!CURRENT_PERCENT!"=="N/A" (
    echo    [WARNING] BitLocker status could not be retrieved for drive %DRIVE%.
    echo    Verify BitLocker is enabled and this script is running as Administrator.
    echo.
    echo    Retrying in %REFRESH_SEC% seconds...  ^(Press CTRL+C to exit^)
    echo  ================================================================
    timeout /t %REFRESH_SEC% /nobreak >nul
    goto LOOP
)

:: ----------------------------------------------------------------
::  NOT ENCRYPTED CHECK
::  Fires if manage-bde reports the drive is fully decrypted.
::  "Fully Decrypted" is the conversion status for a drive that
::  has no BitLocker encryption applied at all, or has finished
::  being decrypted. Checked before all other logic so the script
::  exits immediately rather than attempting to monitor a drive
::  that has nothing to monitor.
:: ----------------------------------------------------------------
findstr /i "Fully Decrypted" "%TMPFILE%" >nul 2>&1
if !errorlevel! equ 0 (
    del "%TMPFILE%" >nul 2>&1
    goto NOT_ENCRYPTED
)

:: ----------------------------------------------------------------
::  COMPLETION CHECKS
::
::  *** WHY WE SEARCH THE RAW FILE INSTEAD OF COMPARING VARIABLES ***
::
::  The % character in "100.0%" is a special character in CMD batch
::  files that triggers variable expansion. Using it in an IF
::  comparison ( if "!VAR!"=="100.0%" ) causes CMD's parser to
::  misread the expression and the comparison silently fails even
::  when the value is correct. Searching the raw manage-bde output
::  file with findstr completely bypasses this parsing issue.
:: ----------------------------------------------------------------

:: PRIMARY: Check if the Percentage Encrypted line contains 100
findstr /i "Percentage Encrypted" "%TMPFILE%" | findstr "100" >nul 2>&1
if !errorlevel! equ 0 (
    del "%TMPFILE%" >nul 2>&1
    goto DONE
)

:: SECONDARY: Check conversion status text for full encryption
findstr /i "Fully Encrypted" "%TMPFILE%" >nul 2>&1
if !errorlevel! equ 0 (
    del "%TMPFILE%" >nul 2>&1
    goto DONE
)

:: SECONDARY: Catch used-space-only (quick-encrypt) completion
findstr /i "Used Space Only Encrypted" "%TMPFILE%" >nul 2>&1
if !errorlevel! equ 0 (
    del "%TMPFILE%" >nul 2>&1
    goto DONE
)

:: ----------------------------------------------------------------
::  STALL DETECTION
::  NOTE: Runs regardless of conversion status text.
::  When BitLocker stalls, Windows may report a non-"Encrypting"
::  status -- percentage comparison is the only reliable indicator.
:: ----------------------------------------------------------------
if "!LAST_PERCENT!"=="INIT" (
    :: First run -- capture baseline, skip stall evaluation
    set "LAST_PERCENT=!CURRENT_PERCENT!"
    echo    [INFO] Baseline percentage captured: !CURRENT_PERCENT!
    echo.
    goto SKIP_STALL
)

if "!CURRENT_PERCENT!"=="!LAST_PERCENT!" (

    set /a "STALL_COUNT+=1"
    echo    [STALL ALERT] Percentage unchanged since last check.
    echo    Stall count  : !STALL_COUNT! / %MAX_STALL%
    set /a "STALL_SECS=!STALL_COUNT! * %REFRESH_SEC%"
    echo    Time stalled : approx. !STALL_SECS! seconds
    echo.

    :: Trigger recovery after 5-minute stall
    if !STALL_COUNT! geq %MAX_STALL% (
        echo    *** STALL THRESHOLD REACHED - INITIATING PAUSE/RESUME RECOVERY ***
        echo.
        echo    [PAUSE]   Pausing BitLocker encryption on %DRIVE%...
        manage-bde -pause %DRIVE% >nul 2>&1
        echo    [WAIT]    Holding for 5 seconds...
        timeout /t 5 /nobreak >nul
        echo    [RESUME]  Resuming BitLocker encryption on %DRIVE%...
        manage-bde -resume %DRIVE% >nul 2>&1
        set "STALL_COUNT=0"
        set /a "RESUME_COUNT+=1"
        echo    [DONE]    Recovery attempt #!RESUME_COUNT! complete. Stall counter reset.
        echo.
    )

) else (

    if !STALL_COUNT! gtr 0 (
        echo    [PROGRESS RESUMED] Encryption is moving again. Stall counter reset.
        echo.
    )
    set "STALL_COUNT=0"
    set "LAST_PERCENT=!CURRENT_PERCENT!"

)

:SKIP_STALL

:: ----------------------------------------------------------------
::  Auto-Resume if Encryption is Externally Paused
:: ----------------------------------------------------------------
echo !CONV_STATUS! | findstr /i "Paused" >nul
if !errorlevel! equ 0 (
    echo    [AUTO-RESUME] Encryption is paused. Attempting to resume...
    manage-bde -resume %DRIVE% >nul 2>&1
    if !errorlevel! equ 0 (
        echo    [OK] Encryption resumed successfully.
    ) else (
        echo    [WARN] Auto-resume failed. Manual intervention may be required.
    )
    echo.
)

:: ----------------------------------------------------------------
::  Informational Status Note (display only -- no branching)
:: ----------------------------------------------------------------
echo !CONV_STATUS! | findstr /i "Encryp" >nul
if !errorlevel! neq 0 (
    echo    [NOTE] Conversion status "!CONV_STATUS!" may indicate a temporary
    echo    state change. Stall detection remains active.
    echo.
)

:: ----------------------------------------------------------------
::  Wait Before Next Refresh
:: ----------------------------------------------------------------
echo  ----------------------------------------------------------------
echo    Refreshing in %REFRESH_SEC% seconds.
echo    Press CTRL+C to stop monitoring.
echo  ================================================================
timeout /t %REFRESH_SEC% /nobreak >nul
goto LOOP


:: ================================================================
::  DRIVE NOT ENCRYPTED
::  Fires if the drive is fully decrypted / BitLocker not enabled.
:: ================================================================
:NOT_ENCRYPTED
cls
echo.
echo  ================================================================
echo.
echo          *** DRIVE IS NOT ENCRYPTED ***
echo.
echo  ================================================================
echo.
echo    Drive            :  %DRIVE%
echo    Conversion Status:  Fully Decrypted
echo    Checked On       :  %date%
echo    Checked At       :  %time%
echo.
echo  ================================================================
echo.
echo    Drive %DRIVE% does not have BitLocker encryption applied.
echo    If encryption was expected, please verify BitLocker has been
echo    enabled on this device before running this monitor.
echo.
echo    Press any key to close this window.
echo.
pause >nul
exit /b 0


:: ================================================================
::  ENCRYPTION COMPLETE
::  Loop exits here -- no further refreshes occur.
:: ================================================================
:DONE
cls
echo.
echo  ================================================================
echo.
echo          *** BITLOCKER ENCRYPTION COMPLETE ***
echo.
echo  ================================================================
echo.
echo    Drive            :  %DRIVE%
echo    Final Status     :  !CONV_STATUS!
echo    Final Percentage :  !CURRENT_PERCENT!
echo    Completed On     :  %date%
echo    Completed At     :  %time%
echo.
if !RESUME_COUNT! gtr 0 (
    echo    NOTE: Encryption stalled !RESUME_COUNT! time^(s^) during this session
    echo    and was automatically recovered via pause/resume.
    echo.
)
echo  ================================================================
echo.
echo    BitLocker encryption has finished successfully.
echo    Press any key to close this window.
echo.
pause >nul
exit /b 0
